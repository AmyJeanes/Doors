-- Managed BASS channels. A listener crossing a door portal jumps the ear thousands of units, which culls
-- an EmitSound one-shot with no way to resume it; a BASS channel isn't spatialised by Source, so it plays
-- through the jump. The cost is that everything Source would have done is done by hand each frame, from
-- cl_engine_mix.lua. Doppler isn't emulated (Source only applies it to CHAR_DOPPLER soundscripts).

---@class doors_sound_module
---@field culling doors_sound_culling
---@field culling_defaults doors_sound_culling
---@field play fun(opts: doors_sound_opts): doors_managed_sound

local Sound = Doors.Sound

-- How long an intro takes to hand over to the looping body. Its job is to leave no hard boundary for a
-- late frame to miss, so it stays a fade even at a bad frame rate; much below this it collapses into a
-- step and becomes a splice again. cl_wav.lua reads it as the threshold for honouring a loop marker at
-- all, an intro shorter than its own handover never being heard.
local HANDOVER = 0.15
Sound.handover = HANDOVER

--------------------------------------------------------------------------------------------------
-- Engine comparison mode
--------------------------------------------------------------------------------------------------

-- The A/B: play it as a plain CSoundPatch instead, giving up everything managed channels are for, to
-- compare the port against the original when one of them sounds wrong. Only volume and pitch stay ours
-- to drive, those being the pre-distance values a CSoundPatch takes too.
local engineMode = CreateClientConVar("doors_sound_engine", "0", false, false,
    "Play sounds through the engine's own CSoundPatch instead of a managed channel, to compare the two")

-- Restart everything so flipping it takes effect at once - a loop's owner polls its handle and remakes
-- it next Think, which is the ownership pattern the library already relies on.
cvars.AddChangeCallback("doors_sound_engine", function()
    local list = Sound.active
    for i = #list, 1, -1 do
        list[i]:Stop()
    end
end, "doors_sound_engine_restart")

--------------------------------------------------------------------------------------------------
-- Virtualisation
--------------------------------------------------------------------------------------------------

-- Unpark sits above park so the async reload lands before the sound is audible again and the two cannot
-- flap, and park must clear Source's own distance-gain floor (which clamps an open-world sound at -60 dB
-- at range) or nothing in the open world ever parks.
---@class doors_sound_culling
---@field park_db number applied-gain floor in dB a channel must sit below to be freed
---@field unpark_db number applied-gain floor in dB it must climb back above to reload, above park_db
---@field delay number seconds below the park floor before the channel is freed
local CULLING_DEFAULTS = {
    park_db   = -54,
    unpark_db = -50,
    delay     = 3,
}
Sound.culling = table.Copy(CULLING_DEFAULTS) ---@type doors_sound_culling
Sound.culling_defaults = CULLING_DEFAULTS ---@type doors_sound_culling

---@param db number
---@return number gain
local function dbToGain(db) return 10 ^ (db / 20) end

--------------------------------------------------------------------------------------------------
-- Handle
--------------------------------------------------------------------------------------------------

-- The class attaches to the metatable, so the methods defined on it below land on the handle type.

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

-- How long a failed load still reads as alive before an owner may remake it. A missing file is retried in
-- case the mount has not finished, and an owner polls every frame. Not applied to a channel that was
-- playing and got stopped from outside, which recreates cleanly and should come straight back.
local RETRY_COOLDOWN = 5

-- Warned once per path, not once per attempt: the retry above brings the same missing file back around
-- every few seconds, and an owner may hold several, so per-attempt warnings would bury the console.
local warnedPaths = {}

-- Marking it stopped is what makes a load still in flight free its own channel on arrival, rather than
-- attach it to a handle nothing can reach.
---@param handle doors_managed_sound
local function drop(handle)
    handle.stopped = true
    if handle.patch then
        handle.patch:Stop()
        handle.patch = nil
    end
    if IsValid(handle.chan) then handle.chan:Stop() end
    -- an intro still handing over to its loop goes too, as does a body loaded and waiting for one
    if IsValid(handle.intro) then handle.intro:Stop() end
    if IsValid(handle.body) then handle.body:Stop() end
    handle.chan, handle.intro, handle.body, handle.xfade = nil, nil, nil, nil
    table.RemoveByValue(Sound.active, handle)
end

-- CSoundPatch::ChangeVolume caps its target at 1, and PlayEx routes through it - so content carrying a
-- volume of 10 or 50 has always been silently given 1. A BASS channel amplifies instead, so the cap has
-- to be reproduced. On the caller's volume, not the result after distance, which would carry ten times
-- as far.
---@param volume number?
---@return number
local function callerVolume(volume)
    return math.Clamp(volume or 1, 0, 1)
end

--------------------------------------------------------------------------------------------------
-- Per-frame gain and rate
--------------------------------------------------------------------------------------------------

local volumeConVar = GetConVar("volume") -- BASS bypasses the convar EmitSound obeys, so fold it in

-- base * distance gain * doorway * occlusion * mixer * master. Omni (stereo-wav) sounds are unattenuated
-- by direction and never obscured, so they skip occlusion.
---@param handle doors_managed_sound
---@param res doors_sound_resolution
---@return number
local function targetVolume(handle, res)
    -- res.applied needs no cap: every part of it only takes away, and the glide interpolates between two
    -- such values. Occlusion stays outside it, carrying its own smoothing.
    local gain = res.applied
    if res.pos and not handle.omni then
        gain = gain * Sound.occlusion(handle, res.pos)
    end
    return handle.base * gain * Sound.mixer_gain * (volumeConVar and volumeConVar:GetFloat() or 1)
end

local OMNI_ENVELOPE = 0.9 -- GetSpeakerVol's fully-mono target per front speaker (both sides equal)

-- Apply this frame's level and pan: the spatialiser's left/right mapped onto a stereo BASS channel via
-- SetVolume (the louder side) + SetPan (the ratio between them). Mid-handover both channels are live, so
-- each takes the same placement at an equal-power share of the volume.
---@param handle doors_managed_sound
local function applyGain(handle)
    local res = Sound.resolve(handle)
    local scalar = targetVolume(handle, res)
    local pos = res.pos
    local pan = 0
    if pos and handle.omni then
        handle.volume = scalar * OMNI_ENVELOPE
    elseif pos then
        -- Across a boundary the sound is heard from the doorway, which is a hole rather than an object,
        -- so there is no emitter radius to collapse toward mono inside.
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

-- Both channels, since an intro and its loop are audible together for the whole crossfade - rating only
-- the incoming one leaves the two detuned.
---@param handle doors_managed_sound
local function applyRate(handle)
    local rate = handle.rate
    if IsValid(handle.chan) then handle.chan:SetPlaybackRate(rate) end
    if IsValid(handle.intro) then handle.intro:SetPlaybackRate(rate) end
end

--------------------------------------------------------------------------------------------------
-- Handle methods
--------------------------------------------------------------------------------------------------

-- "has a channel", which a handle does not for the frame or two its load is in flight. So don't gate
-- per-frame updates on this: they would all be skipped until the channel exists, leaving it to start at
-- whatever the volume was when it was created and jump on the next frame.

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

-- What an owner polls to keep a loop alive, rather than testing its handle for nil: a dead handle is
-- delisted but stays non-nil in whatever field the owner put it in, so a nil test leaves a corpse there
-- and the loop never comes back. True while a load is in flight, so the owner does not start a second
-- copy every frame until the first lands.

---@api
---@return boolean
function MANAGED:IsAlive()
    -- tested ahead of `stopped`, because dropping a handle sets both
    if self.retry_after ~= nil and RealTime() < self.retry_after then return true end
    if self.stopped then return false end
    if self.parked then return true end -- channel freed, handle deliberately kept
    if self.loading then return true end
    return self:IsValid()
end

-- BASS has a slide of its own, but GMod doesn't expose it, so a fade is run from the Think loop below.

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
    -- through the gain path rather than writing the channel: the caller's volume is the pre-distance
    -- one, so writing it straight to the channel would play a far-off sound at full volume
    applyGain(self)
end

-- Fade out and stop, for a loop that shouldn't just cut off.

---@api
---@param time number seconds
function MANAGED:FadeOut(time)
    if not (time and time > 0) then return self:Stop() end
    -- a parked sound is silent and parkThink runs no fade, so there is nothing to fade out
    if self.parked then return self:Stop() end
    self.fade_to = 0
    self.fade_left = time
    self.stop_when_faded = true
end

-- Playback rate doubles as pitch, the same way Source's does - both resample, so speed and pitch move
-- together. `ease` matches the engine's own pitch glide, keeping a per-frame target (flight speed,
-- doppler) from arriving as steps.

---@api
---@param pitch number percent, 100 = the file's own pitch
---@param ease number? seconds to glide over; omitted or 0 applies it immediately
function MANAGED:SetPitch(pitch, ease)
    -- floored ahead of the split so both paths answer a zero alike: a rate of zero is not a slow sound
    pitch = math.max(pitch, 1)
    local patch = self.patch
    if patch then
        patch:ChangePitch(pitch, ease or 0) -- a CSoundPatch eases a pitch change itself
        -- recorded even so: a one-shot on this path ends by its own length, and resampling changes it
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

-- EmitSound's default sound level; the SNDLVL_* names aren't Lua globals, so 75
local DEFAULT_SNDLVL = 75

-- SP-pause watcher state (the PreRender hook at the bottom). SinglePlayer can't change within a session,
-- so read it once instead of per frame.
local SINGLEPLAYER = game.SinglePlayer()
local sp_paused = false
local last_think_frame = 0

-- Apply this frame's gain before it is heard (noplay kept it silent), seek a resuming one-shot to its
-- logical clock, then play - paused straight away if the load landed mid-pause.
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

-- A load that failed - a genuinely missing file, not a channel stopped from outside.
---@param handle doors_managed_sound
---@param path string
---@param errId number?
---@param errName string?
local function onLoadFail(handle, path, errId, errName)
    if not warnedPaths[path] then
        warnedPaths[path] = true
        -- Non-halting: this is an async callback detached from whoever asked for the sound, so a raised
        -- error would break an unrelated Think and its stack trace would point here, not at the content
        -- that named the missing file.
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

    -- A CSoundPatch has to hang off an entity, so a sound given only a fixed position stays on the
    -- managed channel - it is the one case with no engine equivalent to compare against.
    if engineMode:GetBool() and IsValid(opts.ent) then
        local patch = CreateSound(opts.ent --[[@as Entity]], opts.path)
        handle.patch = patch
        handle.loading = false
        patch:PlayEx(handle.base, 100)
        return handle
    end

    -- Born parked: below the cull floor already, no channel is loaded at all. A one-shot must still end on
    -- its own while parked, so one whose length is unknown loads once to learn it rather than never end.
    Sound.resolve(handle)
    if handle.res.applied < dbToGain(Sound.culling.park_db) and (handle.loop or handle.duration) then
        handle.parked = true
        handle.loading = false
        return handle
    end

    -- A loop whose file opens with an intro plays it from the original and hands over to a trimmed copy
    -- BASS can loop whole-file. Both load before either is heard, so the body is ready on the exact frame.
    local bodyPath = handle.loop and handle.loop_start > 0
        and Sound.loop_body_file(opts.path, handle.loop_start) or nil

    -- Stereo, like Source: a positioned stereo sound keeps its channels, each scaled by that side's
    -- spatialisation weight (not summed to mono). noblock fully loads so there's no block-stream hitch.
    -- noplay keeps a channel at its first sample until it is wanted - PlayFile starts it otherwise.
    sound.PlayFile("sound/" .. opts.path, "noblock noplay", function(chan, errId, errName)
        handle.loading = false
        if handle.stopped then
            if IsValid(chan) then chan:Stop() end -- stopped before the load finished
        elseif IsValid(chan) then
            -- learn the length once per path from the channel itself - BASS is the oracle, no header
            -- parse - so a later born-parked one-shot of this path knows when it ends without loading
            if not handle.loop and handle.duration == nil then
                local len = chan:GetLength() ---@type number?
                if len and len > 0 then
                    handle.duration = len
                    header.duration = len
                end
            end
            -- with a body to hand over to, this channel is only playing the intro, so it must not loop
            startChannel(handle, chan, handle.loop and bodyPath == nil)
        else
            onLoadFail(handle, opts.path, errId, errName)
        end
    end)

    if bodyPath then
        sound.PlayFile("data/" .. bodyPath, "noblock noplay", function(chan)
            if handle.stopped or not IsValid(chan) then
                if IsValid(chan) then chan:Stop() end
                -- without a body there is nothing to hand over to, so let the original loop whole-file:
                -- its intro comes back around each cycle, which is wrong but never silent
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

-- Linear over the requested time, stepped by frame rather than clock so it freezes with the game like
-- the sound itself does.
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

-- Exponential, so it closes most of the gap within the requested time and settles without overshoot.
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

-- Crossfaded rather than cut, so there is no instant for a late frame to miss. The two are playing
-- consecutive samples, before and after the marker - overlapping the *same* audio would comb-filter.
---@param handle doors_managed_sound
local function stepHandover(handle)
    if handle.xfade == nil then
        local body, intro = handle.body, handle.chan
        if body == nil or not IsValid(body) or not IsValid(intro) then return end
        if intro:GetState() ~= GMOD_CHANNEL_PLAYING then return end
        if intro:GetTime() < handle.loop_start - HANDOVER then return end
        -- the body takes over as the handle's channel; the original becomes the outgoing intro
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

-- chan:Stop() destroys the channel and frees the file lock, which is what is wanted: the owner keeps
-- polling IsAlive and never remakes it, and resolve() keeps running so the handle knows when to return.
---@param handle doors_managed_sound
local function park(handle)
    if IsValid(handle.chan) then handle.chan:Stop() end
    if IsValid(handle.intro) then handle.intro:Stop() end
    if IsValid(handle.body) then handle.body:Stop() end
    handle.chan, handle.intro, handle.body, handle.xfade = nil, nil, nil, nil
    handle.below_since = nil
    handle.parked = true
end

-- A one-shot resumes from its logical clock; a loop resumes fresh into its body, with no intro replay and
-- no phase to align. Frame accuracy is plenty, the reload landing while it is still below hearing.
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

-- Keep resolving so it knows when to wake, and end a one-shot that ran out while parked by its clock,
-- there being no channel state left to read.
---@param handle doors_managed_sound
local function parkThink(handle)
    local res = Sound.resolve(handle)
    if not handle.loop and handle.duration and handle.clock >= handle.duration then
        handle:Stop()
        return
    end
    if res.applied >= dbToGain(Sound.culling.unpark_db) then unpark(handle) end
end

-- A fade or intro handover in flight is left to finish first, both being transient states a freed channel
-- could not resume cleanly.
---@param handle doors_managed_sound
local function parkCheck(handle)
    if handle.fade_left or handle.xfade ~= nil then
        handle.below_since = nil
        return
    end
    if handle.res.applied < dbToGain(Sound.culling.park_db) then
        handle.below_since = handle.below_since or RealTime()
        if RealTime() - handle.below_since >= Sound.culling.delay then park(handle) end
    else
        handle.below_since = nil
    end
end

--------------------------------------------------------------------------------------------------
-- Think
--------------------------------------------------------------------------------------------------

-- CSoundPatch:IsPlaying answers for the patch's own play/stop flag, not for the audio - a finished
-- one-shot reports true indefinitely - so time one out against its own length and leave IsPlaying to
-- catch what it does answer for: stopped from outside. No length means never dropping it, which is the
-- safe way to be wrong, since dropping stops the patch.
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
            -- the engine owns everything about this one except the caller's own volume, so only the fade
            -- still needs running - and it feeds the same pre-distance value ChangeVolume takes
            stepFade(handle)
            local patch = handle.patch
            if patch and not handle.stopped then -- a fade can end in a stop, which drops the handle
                handle.clock = handle.clock + FrameTime() * handle.rate
                if patchFinished(handle, patch) then
                    -- dropped like a managed channel that stopped, so a one-shot stops being ticked
                    -- forever and an owner polling IsAlive sees a finished loop die and remakes it
                    drop(handle)
                else
                    patch:ChangeVolume(handle.base, 0)
                end
            end
        else
            stepHandover(handle)
            -- The logical clock advances on game time - frozen during a pause, since Think does not run
            -- then - for parked and live handles alike, so a resumed one-shot picks up where it left off.
            handle.clock = handle.clock + FrameTime() * handle.rate
            local chan = handle.chan
            if chan == nil then
                if handle.parked then
                    parkThink(handle)
                elseif handle.loading then
                    -- a handle still loading has to keep resolving too: the position it tracks feeds a
                    -- paired sibling's space and the jump test's per-frame budget, and both answer
                    -- nonsense from a position last taken several frames ago
                    Sound.resolve(handle)
                end
            elseif not IsValid(chan) or chan:GetState() == GMOD_CHANNEL_STOPPED then
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

-- Native EmitSounds freeze with the engine but BASS plays on, so pause the channels with the game. GMod
-- exposes no pause hook, but render hooks keep running through a pause while Think freezes completely, so
-- render frames with no Think detect it within ~2 frames. Singleplayer only: in multiplayer a Think stall
-- is net lag, through which native sounds keep playing, so pausing would create a divergence.
hook.Add("PreRender", "doors_managed_sounds_pause", function()
    if not SINGLEPLAYER or last_think_frame == 0 then return end
    local now_paused = FrameNumber() - last_think_frame >= 2
    if now_paused == sp_paused then return end
    sp_paused = now_paused
    for _, handle in ipairs(Sound.active) do
        -- both, when an intro is mid-handover to its loop
        for _, chan in ipairs({ handle.chan, handle.intro }) do
            if IsValid(chan) then
                if sp_paused and chan:GetState() == GMOD_CHANNEL_PLAYING then
                    chan:Pause()
                    handle.sp_paused = true
                elseif not sp_paused and handle.sp_paused then
                    -- resume only what we parked and is still parked: Play() on a channel that finished
                    -- in the detection window would restart it from the beginning
                    if chan:GetState() == GMOD_CHANNEL_PAUSED then
                        chan:Play()
                    end
                end
            end
        end
        if not sp_paused then handle.sp_paused = nil end
    end
end)
