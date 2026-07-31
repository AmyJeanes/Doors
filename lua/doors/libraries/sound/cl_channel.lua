---@class doors_sound_module
---@field park_db number
---@field unpark_db number
---@field park_delay number
---@field play fun(opts: doors_sound_opts): doors_managed_sound

local Sound = Doors.Sound

local HANDOVER = 0.15
Sound.handover = HANDOVER

--------------------------------------------------------------------------------------------------
-- Engine comparison mode
--------------------------------------------------------------------------------------------------

local engineMode = CreateClientConVar("doors_sound_engine", "0", false, false,
    "Play sounds through the engine's own CSoundPatch instead of a managed channel, to compare the two")

cvars.AddChangeCallback("doors_sound_engine", function()
    local list = Sound.active
    for i = #list, 1, -1 do
        list[i]:Stop()
    end
end, "doors_sound_engine_restart")

--------------------------------------------------------------------------------------------------
-- Virtualisation
--------------------------------------------------------------------------------------------------

-- unpark must sit above park or the two flap, and park must clear Source's own distance-gain floor
-- (-60 dB at range) or nothing in the open world ever parks.
Sound.park_db = -54
Sound.unpark_db = -50
Sound.park_delay = 3

local PARK_GAIN = 10 ^ (Sound.park_db / 20)
local UNPARK_GAIN = 10 ^ (Sound.unpark_db / 20)

--------------------------------------------------------------------------------------------------
-- Handle
--------------------------------------------------------------------------------------------------

-- The class attaches to the metatable, so the methods below land on the handle type.

---@class doors_managed_sound
---@field path string sound path relative to sound/
---@field intro IGModAudioChannel? the original file, playing the part before the loop marker
---@field xfade number? progress 0-1 of the intro handing over to the loop
---@field chan IGModAudioChannel? nil while the async load is still in flight
---@field patch CSoundPatch? set instead of chan under doors_sound_engine, where the engine plays it
---@field owner Entity?
---@field tag string?
---@field base number caller's max volume (the EmitSound volume equivalent)
---@field volume number current applied volume
---@field ent Entity? source entity for distance falloff (offset applied in its local space)
---@field pos Vector? fixed world source position for falloff (used when ent is not set)
---@field offset Vector? local offset from ent for the source position
---@field level number? SNDLVL for distance falloff (needs a source: ent or pos)
---@field pin_on_jump number? see doors_sound_opts
---@field attach Entity? see doors_sound_opts
---@field attach_dist number distance from pos at which attach takes over as the source
---@field occ number? smoothed occlusion gain
---@field omni boolean true for a stereo .wav - Source plays it omnidirectional (mono, no pan, unobscured)
---@field sp_paused boolean? true while parked by the SP-pause watcher
---@field stopped boolean
---@field loading boolean true until the async load resolves, either way - see IsAlive
---@field retry_after number? RealTime a dropped handle may be remade after, rate-limiting a failed load
---@field loop boolean? repeats until stopped
---@field loop_start number seconds into the file its loop begins, 0 for a plain whole-file loop
---@field body IGModAudioChannel? the trimmed loop body, waiting for the intro to hand over to it
---@field clock number logical playback position in seconds, advanced whether or not a channel exists
---@field duration number? one-shot length in seconds, learned from the channel and cached per path
---@field parked boolean? true while virtualised - the handle is kept but its BASS channel freed
---@field below_since number? RealTime the applied gain first dropped below the park floor
---@field fade_to number? volume being faded toward
---@field fade_left number? seconds of fade remaining
---@field stop_when_faded boolean? stop the sound once the running fade finishes
---@field rate number current playback rate, 1 = the file's own pitch
---@field rate_to number? playback rate being eased toward
---@field rate_ease number? seconds the rate ease takes to close most of the gap
local MANAGED = {}
MANAGED.__index = MANAGED

local RETRY_COOLDOWN = 5

local warnedPaths = {}

---@param handle doors_managed_sound
local function drop(handle)
    handle.stopped = true
    if handle.patch then
        handle.patch:Stop()
        handle.patch = nil
    end
    if IsValid(handle.chan) then handle.chan:Stop() end
    if IsValid(handle.intro) then handle.intro:Stop() end
    if IsValid(handle.body) then handle.body:Stop() end
    handle.chan, handle.intro, handle.body, handle.xfade = nil, nil, nil, nil
    table.RemoveByValue(Sound.active, handle)
end

-- CSoundPatch::ChangeVolume caps its target at 1, so content carrying a volume of 10 or 50 has always
-- been silently given 1. A BASS channel amplifies instead, so the cap has to be reproduced.
---@param volume number?
---@return number
local function callerVolume(volume)
    return math.Clamp(volume or 1, 0, 1)
end

--------------------------------------------------------------------------------------------------
-- Per-frame gain and rate
--------------------------------------------------------------------------------------------------

---@param handle doors_managed_sound
---@param res doors_sound_resolution
---@return number
local function targetVolume(handle, res)
    local gain = res.applied
    if res.pos and not handle.omni then
        gain = gain * Sound.occlusion(handle, res.pos)
    end
    -- No `volume` term: GMod already applies that convar to a BASS channel, so folding it in squares it.
    return handle.base * gain * Sound.mixer_gain
end

local OMNI_ENVELOPE = 0.9 -- GetSpeakerVol's fully-mono target per front speaker (both sides equal)

---@param handle doors_managed_sound
local function applyGain(handle)
    local res = Sound.resolve(handle)
    local scalar = targetVolume(handle, res)
    local pos = res.pos
    local pan = 0
    if pos and handle.omni then
        handle.volume = scalar * OMNI_ENVELOPE
    elseif pos then
        local radius = 0
        if res.int == nil and IsValid(handle.ent) then radius = handle.ent:GetModelRadius() end
        local lf, rf = Sound.spatialize(pos, radius)
        local m = math.max(lf, rf, 0.0001)
        handle.volume = scalar * m
        pan = (rf - lf) / m
    else
        handle.volume = scalar
    end

    local x = handle.xfade
    local main, intro = handle.chan, handle.intro
    if main ~= nil and IsValid(main) then
        main:SetVolume(handle.volume * (x and math.sin(x * math.pi / 2) or 1))
        main:SetPan(pan)
    end
    if intro ~= nil and IsValid(intro) then
        intro:SetVolume(handle.volume * (x and math.cos(x * math.pi / 2) or 1))
        intro:SetPan(pan)
    end
end

---@param handle doors_managed_sound
local function applyRate(handle)
    local rate = handle.rate
    if IsValid(handle.chan) then handle.chan:SetPlaybackRate(rate) end
    if IsValid(handle.intro) then handle.intro:SetPlaybackRate(rate) end
end

--------------------------------------------------------------------------------------------------
-- Handle methods
--------------------------------------------------------------------------------------------------

---@api
---@return boolean
function MANAGED:IsValid()
    if self.patch then return true end
    return IsValid(self.chan)
end

---@api
function MANAGED:IsPlaying()
    local patch = self.patch
    if patch then return patch:IsPlaying() end
    return IsValid(self.chan) and self.chan:GetState() == GMOD_CHANNEL_PLAYING
end

---@api
---@return boolean
function MANAGED:IsAlive()
    if self.retry_after ~= nil and RealTime() < self.retry_after then return true end
    if self.stopped then return false end
    if self.parked then return true end -- channel freed, handle deliberately kept
    if self.loading then return true end
    return self:IsValid()
end

---@api
---@param volume number
---@param time number? seconds to fade over; omitted or 0 applies it immediately
function MANAGED:SetVolume(volume, time)
    volume = callerVolume(volume)
    if time and time > 0 then
        self.fade_to = volume
        self.fade_left = time
        return
    end
    self.fade_to, self.fade_left, self.stop_when_faded = nil, nil, nil
    self.base = volume
    local patch = self.patch
    if patch then
        patch:ChangeVolume(volume, 0) -- a CSoundPatch takes the pre-distance volume itself
        return
    end
    applyGain(self)
end

---@api
---@param time number seconds
function MANAGED:FadeOut(time)
    if not (time and time > 0) then return self:Stop() end
    if self.parked then return self:Stop() end
    self.fade_to = 0
    self.fade_left = time
    self.stop_when_faded = true
end

---@api
---@param pitch number percent, 100 = the file's own pitch
---@param ease number? seconds to glide over; omitted or 0 applies it immediately
function MANAGED:SetPitch(pitch, ease)
    pitch = math.max(pitch, 1)
    local patch = self.patch
    if patch then
        patch:ChangePitch(pitch, ease or 0) -- a CSoundPatch eases a pitch change itself
        self.rate = pitch / 100
        return
    end
    local rate = pitch / 100
    if ease and ease > 0 then
        self.rate_to = rate
        self.rate_ease = ease
        return
    end
    self.rate_to, self.rate_ease = nil, nil
    self.rate = rate
    applyRate(self)
end

---@api
function MANAGED:Stop()
    drop(self)
end

--------------------------------------------------------------------------------------------------
-- Starting a sound
--------------------------------------------------------------------------------------------------

-- EmitSound's default; the SNDLVL_* names aren't Lua globals
local DEFAULT_SNDLVL = 75

local SINGLEPLAYER = game.SinglePlayer()
local sp_paused = false
local last_think_frame = 0

---@param handle doors_managed_sound
---@param chan IGModAudioChannel
---@param loop boolean whether this channel loops (false for an intro-only channel or a one-shot)
---@param seekTo number? seconds to resume from, for a one-shot returning from park
local function startChannel(handle, chan, loop, seekTo)
    handle.chan = chan
    if loop then chan:EnableLooping(true) end
    if handle.rate ~= 1 then chan:SetPlaybackRate(handle.rate) end
    if seekTo and seekTo > 0 then chan:SetTime(seekTo) end
    applyGain(handle)
    chan:Play()
    if sp_paused then
        chan:Pause()
        handle.sp_paused = true
    end
end

---@param handle doors_managed_sound
---@param path string
---@param errId number?
---@param errName string?
local function onLoadFail(handle, path, errId, errName)
    if not warnedPaths[path] then
        warnedPaths[path] = true
        ErrorNoHalt(string.format("[Doors] sound '%s' failed to load (%s)\n",
            path, errName or errId or "unknown error"))
    end
    handle.retry_after = RealTime() + RETRY_COOLDOWN
    drop(handle)
end

---@param opts doors_sound_opts
---@return doors_managed_sound
local function playManaged(opts)
    local header = Sound.header(opts.path)
    ---@type doors_managed_sound
    local handle = setmetatable({
        path = opts.path,
        owner = opts.owner,
        pair = opts.pair,
        through_doors = opts.through_doors and math.Clamp(opts.through_doors, 0, 1) or nil,
        tag = opts.tag,
        base = callerVolume(opts.volume),
        volume = callerVolume(opts.volume),
        ent = opts.ent,
        pos = opts.pos,
        offset = opts.offset,
        level = opts.level or ((opts.ent ~= nil or opts.pos ~= nil) and DEFAULT_SNDLVL or nil),
        pin_on_jump = opts.pin_on_jump,
        attach = opts.attach,
        attach_dist = opts.attach_dist or 500,
        omni = header.omni,
        loop = opts.loop,
        loop_start = header.loop_start,
        duration = header.duration,
        clock = 0,
        rate = 1,
        stopped = false,
        loading = true,
        res = Sound.new_resolution(),
        res_frame = -1,
        heal_left = 0,
        heal_span = Sound.transition_floor,
    }, MANAGED)
    table.insert(Sound.active, handle)

    if engineMode:GetBool() and IsValid(opts.ent) then
        local patch = CreateSound(opts.ent, opts.path)
        handle.patch = patch
        handle.loading = false
        patch:PlayEx(handle.base, 100)
        return handle
    end

    Sound.resolve(handle)
    if handle.res.applied < PARK_GAIN and (handle.loop or handle.duration) then
        handle.parked = true
        handle.loading = false
        return handle
    end

    local bodyPath = handle.loop and handle.loop_start > 0
        and Sound.loop_body_file(opts.path, handle.loop_start) or nil

    -- noblock fully loads so there's no block-stream hitch; noplay holds the channel at its first sample,
    -- which PlayFile otherwise starts.
    sound.PlayFile("sound/" .. opts.path, "noblock noplay", function(chan, errId, errName)
        handle.loading = false
        if handle.stopped then
            if IsValid(chan) then chan:Stop() end -- stopped before the load finished
        elseif IsValid(chan) then
            if not handle.loop and handle.duration == nil then
                local len = chan:GetLength() ---@type number?
                if len and len > 0 then
                    handle.duration = len
                    header.duration = len
                end
            end
            startChannel(handle, chan, handle.loop and bodyPath == nil)
        else
            onLoadFail(handle, opts.path, errId, errName)
        end
    end)

    if bodyPath then
        sound.PlayFile("data/" .. bodyPath, "noblock noplay", function(chan)
            if handle.stopped or not IsValid(chan) then
                if IsValid(chan) then chan:Stop() end
                handle.loop_start = 0
                if IsValid(handle.chan) then handle.chan:EnableLooping(true) end
            else
                handle.body = chan
            end
        end)
    end

    return handle
end
Sound.play = playManaged

--------------------------------------------------------------------------------------------------
-- Per-frame steps
--------------------------------------------------------------------------------------------------

---@param handle doors_managed_sound
local function stepFade(handle)
    local left = handle.fade_left
    if not left then return end
    local dt = math.min(FrameTime(), left)
    local target = handle.fade_to or handle.base
    handle.base = handle.base + (target - handle.base) * (dt / left)
    left = left - dt
    if left <= 0 then
        handle.base = target
        handle.fade_to, handle.fade_left = nil, nil
        if handle.stop_when_faded then
            handle.stop_when_faded = nil
            handle:Stop()
        end
    else
        handle.fade_left = left
    end
end

---@param handle doors_managed_sound
local function stepRate(handle)
    local target = handle.rate_to
    if not target then return end
    local ease = handle.rate_ease or 0.1
    handle.rate = Lerp(math.min(FrameTime() / ease, 1), handle.rate, target)
    if math.abs(handle.rate - target) < 0.001 then
        handle.rate = target
        handle.rate_to = nil
    end
    applyRate(handle)
end

---@param handle doors_managed_sound
local function stepHandover(handle)
    if handle.xfade == nil then
        local body, intro = handle.body, handle.chan
        if body == nil or not IsValid(body) or not IsValid(intro) then return end
        if intro:GetState() ~= GMOD_CHANNEL_PLAYING then return end
        if intro:GetTime() < handle.loop_start - HANDOVER then return end
        handle.intro, handle.chan, handle.body = intro, body, nil
        handle.xfade = 0
        body:EnableLooping(true)
        if handle.rate ~= 1 then body:SetPlaybackRate(handle.rate) end
        body:Play()
        return
    end

    handle.xfade = handle.xfade + FrameTime() / HANDOVER
    if handle.xfade >= 1 then
        handle.xfade = nil
        if IsValid(handle.intro) then handle.intro:Stop() end
        handle.intro = nil
    end
end

--------------------------------------------------------------------------------------------------
-- Park and unpark
--------------------------------------------------------------------------------------------------

---@param handle doors_managed_sound
local function park(handle)
    if IsValid(handle.chan) then handle.chan:Stop() end
    if IsValid(handle.intro) then handle.intro:Stop() end
    if IsValid(handle.body) then handle.body:Stop() end
    handle.chan, handle.intro, handle.body, handle.xfade = nil, nil, nil, nil
    handle.below_since = nil
    handle.parked = true
end

---@param handle doors_managed_sound
local function unpark(handle)
    handle.parked = nil
    handle.loading = true
    if not handle.loop then
        sound.PlayFile("sound/" .. handle.path, "noblock noplay", function(chan, errId, errName)
            handle.loading = false
            if handle.stopped then
                if IsValid(chan) then chan:Stop() end
            elseif IsValid(chan) then
                startChannel(handle, chan, false, handle.clock)
            else
                onLoadFail(handle, handle.path, errId, errName)
            end
        end)
        return
    end
    local body = handle.loop_start > 0 and Sound.loop_body_file(handle.path, handle.loop_start) or nil
    local loadPath = body and ("data/" .. body) or ("sound/" .. handle.path)
    sound.PlayFile(loadPath, "noblock noplay", function(chan, errId, errName)
        handle.loading = false
        if handle.stopped then
            if IsValid(chan) then chan:Stop() end
        elseif IsValid(chan) then
            startChannel(handle, chan, true)
        else
            onLoadFail(handle, handle.path, errId, errName)
        end
    end)
end

---@param handle doors_managed_sound
local function parkThink(handle)
    local res = Sound.resolve(handle)
    if not handle.loop and handle.duration and handle.clock >= handle.duration then
        handle:Stop()
        return
    end
    if res.applied >= UNPARK_GAIN then unpark(handle) end
end

---@param handle doors_managed_sound
local function parkCheck(handle)
    if handle.fade_left or handle.xfade ~= nil then
        handle.below_since = nil
        return
    end
    if handle.res.applied < PARK_GAIN then
        handle.below_since = handle.below_since or RealTime()
        if RealTime() - handle.below_since >= Sound.park_delay then park(handle) end
    else
        handle.below_since = nil
    end
end

--------------------------------------------------------------------------------------------------
-- Think
--------------------------------------------------------------------------------------------------

-- CSoundPatch:IsPlaying answers for the patch's own play/stop flag, not for the audio - a finished
-- one-shot reports true indefinitely - so time one out against its own length instead.
---@param handle doors_managed_sound
---@param patch CSoundPatch
---@return boolean
local function patchFinished(handle, patch)
    if not patch:IsPlaying() then return true end
    if handle.loop then return false end
    local dur = handle.duration
    if dur == nil then
        dur = SoundDuration(handle.path)
        if dur <= 0 then return false end
        handle.duration = dur
    end
    return handle.clock >= dur
end

hook.Add("Think", "doors_managed_sounds", function()
    last_think_frame = FrameNumber()
    local list = Sound.active
    for i = #list, 1, -1 do
        local handle = list[i]
        if handle.owner ~= nil and not IsValid(handle.owner) then
            handle:Stop() -- owner deleted, like the entity's own EmitSounds would have
        elseif handle.patch then
            stepFade(handle)
            local patch = handle.patch
            if patch and not handle.stopped then -- a fade can end in a stop, which drops the handle
                handle.clock = handle.clock + FrameTime() * handle.rate
                if patchFinished(handle, patch) then
                    drop(handle)
                else
                    patch:ChangeVolume(handle.base, 0)
                end
            end
        else
            stepHandover(handle)
            handle.clock = handle.clock + FrameTime() * handle.rate
            local chan = handle.chan
            if chan == nil then
                if handle.parked then
                    parkThink(handle)
                elseif handle.loading then
                    Sound.resolve(handle)
                end
            elseif not IsValid(chan) or chan:GetState() == GMOD_CHANNEL_STOPPED then
                -- A channel stopped from outside is indistinguishable from one an engine hiccup killed,
                -- so the owner remakes it next frame and stopsound is near a no-op on a loop. The sound
                -- settings are the off-switch.
                drop(handle)
            else
                stepFade(handle)
                if not handle.stopped then -- a fade can end in a stop, which drops the handle
                    stepRate(handle)
                    applyGain(handle)
                    parkCheck(handle)
                end
            end
        end
    end
end)

-- GMod exposes no pause hook, but render hooks keep running through a pause while Think freezes, so
-- render frames with no Think detect it. Singleplayer only: in multiplayer a Think stall is net lag.
hook.Add("PreRender", "doors_managed_sounds_pause", function()
    if not SINGLEPLAYER or last_think_frame == 0 then return end
    local now_paused = FrameNumber() - last_think_frame >= 2
    if now_paused == sp_paused then return end
    sp_paused = now_paused
    for _, handle in ipairs(Sound.active) do
        for _, chan in ipairs({ handle.chan, handle.intro }) do
            if IsValid(chan) then
                if sp_paused and chan:GetState() == GMOD_CHANNEL_PLAYING then
                    chan:Pause()
                    handle.sp_paused = true
                elseif not sp_paused and handle.sp_paused then
                    -- Play() on a channel that finished inside the detection window would restart it from the beginning
                    if chan:GetState() == GMOD_CHANNEL_PAUSED then
                        chan:Play()
                    end
                end
            end
        end
        if not sp_paused then handle.sp_paused = nil end
    end
end)
