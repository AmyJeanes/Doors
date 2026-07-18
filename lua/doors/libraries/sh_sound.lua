-- Sound playing for interiors and the things around them. Callers describe the sound and where it comes
-- from, and this picks how to play it - a normal engine sound, or a managed BASS channel for the ones
-- that have to survive the listener jumping across the interior void (opts.resumable).
--
-- Managed BASS channels. Interiors sit thousands of units from their exterior, so a listener crossing a
-- door portal - or a view that snaps out to the exterior - jumps the ear across that void. Source culls
-- an EmitSound one-shot when that happens and can't resume it, which cuts off anything long. A BASS
-- channel isn't spatialised by Source, so it plays through the jump. A resumable sound also returns a
-- handle, so callers stop the exact sound they started instead of guessing paths with Entity:StopSound.
--
-- A positioned managed sound is spatialised by hand on a 2D stereo channel to match Source's positioned
-- EmitSound: the volume tracks Source's own distance gain each frame, plus its occlusion rolloff when a
-- world brush blocks the path (map geometry only, like the engine - the interior's floor is an entity, so
-- it doesn't muffle), and a port of Source's speaker spatialiser (spatialize() below) reproduces its exact
-- left/right per-side gain - the azimuth pan and the centre/rear volume envelope - via SetVolume + SetPan,
-- so it tracks the view like the original. Doppler isn't emulated (Source only applies it to CHAR_DOPPLER
-- soundscripts).

---@class doors_sound_opts
---@field path string sound path relative to sound/
---@field ent Entity? entity the sound plays from
---@field pos Vector? fixed world position to play from, when there is no entity
---@field offset Vector? local offset from ent for the source position
---@field volume number? max volume 0-1, default 1
---@field level number? SNDLVL for distance falloff, default 75 (EmitSound's default)
---@field resumable boolean? play through a managed BASS channel instead of the engine, so the sound survives the listener jumping across the interior void - a door portal crossing or the exterior view toggle - which culls a normal engine sound. Returns a handle
---@field loop boolean? repeat until stopped, from the loop point the file's author baked in. Implies resumable: a loop is by definition long enough to be caught by the listener jumping
---@field owner Entity? owner, for group-stop via Doors:StopSounds (a resumable sound also stops when its owner is removed)
---@field tag string? group label for Doors:StopSounds, e.g. "teleport"
---@field pin_on_jump number? resumable only, with ent: the sound pins where the entity vanished from once it moves faster than this (units/second) - a teleporting emitter leaves its tail behind, e.g. the demat echo a bystander hears. A speed, not a distance: interpolation renders a client-side teleport as a short impossibly-fast slide, never a single-frame jump
---@field attach Entity? resumable only, with pos: entity that takes over as the source once it arrives within attach_dist of pos (e.g. the exterior landing on its materialise point)
---@field attach_dist number? resumable only: arrival distance for attach, default 500

-- The engine's own sound, positioned like the caller asked. Shared by both realms: played on the server
-- it reaches every client by itself, played on a client it is that client's alone.
---@param opts doors_sound_opts
local function playNative(opts)
    if opts.ent == nil and opts.pos == nil then
        -- no source at all: an interface sound, played flat rather than placed in the world
        if CLIENT then surface.PlaySound(opts.path) end
        return
    end
    local ent = opts.ent
    if IsValid(ent) then
        -- EmitSound takes no offset, so an offset sound plays from that fixed point instead of following
        if opts.offset then
            sound.Play(opts.path, ent:LocalToWorld(opts.offset), opts.level, nil, opts.volume)
        else
            ent:EmitSound(opts.path, opts.level, nil, opts.volume)
        end
    elseif opts.pos then
        sound.Play(opts.path, opts.pos, opts.level, nil, opts.volume)
    end
end

if SERVER then
    util.AddNetworkString("Doors-Sound")
    util.AddNetworkString("Doors-SoundStop")

    ---@api
    ---@param opts doors_sound_opts
    function Doors:PlaySound(opts)
        -- The engine broadcasts a plain positioned sound by itself, so only send our own message when a
        -- client has to run it: the BASS channel lives client-side, and an interface sound has no
        -- position for the engine to carry. Fire-and-forget - no handle comes back; stop by group.
        if not (opts.resumable or (opts.ent == nil and opts.pos == nil)) then
            playNative(opts)
            return
        end
        net.Start("Doors-Sound")
        net.WriteString(opts.path)
        net.WriteEntity(opts.owner or NULL)
        net.WriteString(opts.tag or "")
        net.WriteFloat(opts.volume or 1)
        net.WriteEntity(opts.ent or NULL)
        -- the entity's position rides along, so a client that doesn't have it still hears the sound
        -- from where it was rather than everywhere at once
        local pos = opts.pos or (IsValid(opts.ent) and opts.ent:GetPos() or nil)
        net.WriteBool(pos ~= nil)
        if pos then net.WriteVector(pos) end
        net.WriteBool(opts.offset ~= nil)
        if opts.offset then net.WriteVector(opts.offset) end
        net.WriteBool(opts.level ~= nil)
        if opts.level then net.WriteUInt(opts.level, 8) end
        net.WriteBool(opts.resumable == true)
        net.Broadcast()
    end

    ---@api
    ---@param owner Entity
    ---@param tag string?
    function Doors:StopSounds(owner, tag)
        net.Start("Doors-SoundStop")
        net.WriteEntity(owner)
        net.WriteString(tag or "")
        net.Broadcast()
    end

    return
end

-- Source's exact distance gain, ported from the engine (sound_shared.cpp SND_GetGainFromMult), so the
-- falloff matches EmitSound precisely: inverse-distance from the SNDLVL, plus air/foliage loss and the
-- >0.5 soft-knee compression and the min-gain floor. Reads the same convars the engine does. Validated
-- against snd_show's own channel gains at 150/300/600/1200u (matched to 1 part in 255). The obscured
-- (line-of-sight blocked) loss is applied on top of this by occlusion() below.
local SND_GAIN_COMP_THRESH = 0.5
local SND_GAIN_COMP_EXP_MAX = 2.5
local SND_GAIN_COMP_EXP_MIN = 0.8
local SND_DB_MED = 90
local SND_DB_MAX = 140
local snd_refdb = GetConVar("snd_refdb")
local snd_refdist = GetConVar("snd_refdist")
local snd_foliage_db_loss = GetConVar("snd_foliage_db_loss")
local snd_gain_max = GetConVar("snd_gain_max")
local snd_gain_min = GetConVar("snd_gain_min")

---@param dist number
---@param level number SNDLVL (0 = SNDLVL_NONE, no attenuation)
---@return number
local function sndLevelGain(dist, level)
    if level <= 0 then return 1 end
    local refdb = snd_refdb and snd_refdb:GetFloat() or 60
    local refdist = snd_refdist and snd_refdist:GetFloat() or 36
    local dist_mult = (10 ^ (refdb / 20) / 10 ^ (level / 20)) / refdist
    local foliage = snd_foliage_db_loss and snd_foliage_db_loss:GetFloat() or 4
    local relative_dist = dist * dist_mult * (10 ^ (foliage * (dist / 1200) / 20))
    local gain = relative_dist > 0.1 and (1 / relative_dist) or 10
    if gain > SND_GAIN_COMP_THRESH then
        local power = SND_GAIN_COMP_EXP_MAX
        if level > SND_DB_MED then
            power = SND_GAIN_COMP_EXP_MAX + (level - SND_DB_MED) / (SND_DB_MAX - SND_DB_MED)
                * (SND_GAIN_COMP_EXP_MIN - SND_GAIN_COMP_EXP_MAX)
        end
        local Y = -1 / (SND_GAIN_COMP_THRESH ^ power * (SND_GAIN_COMP_THRESH - 1))
        gain = (1 - 1 / (Y * gain ^ power)) * (snd_gain_max and snd_gain_max:GetFloat() or 1)
    end
    local gmin = snd_gain_min and snd_gain_min:GetFloat() or 0.01
    if gain < gmin then
        gain = gmin * (2 - relative_dist * gmin)
        if gain <= 0 then gain = 0.001 end
    end
    return gain
end

-- A file whose loop begins partway in can't be looped correctly by BASS, which always wraps to sample
-- zero - and no amount of seeking from Lua fixes that, because the position we can observe isn't the
-- one being heard. So hand BASS a file that *is* the loop: copy the samples from the marker onwards
-- into data/ once, and loop that whole-file, with nothing per-frame involved. PCM wav only, which is
-- all that carries a marker anyway. The cache key includes the source size so an updated asset
-- rebuilds instead of playing a stale body forever.
---@param path string
---@param from number seconds to trim off the front
---@return string? dataPath relative to data/, nil if the file can't be trimmed
local function loopBodyFile(path, from)
    local src = file.Read("sound/" .. path, "GAME")
    if not src then return nil end
    local key = "doors_loopcache/" .. util.CRC(path .. "_" .. #src) .. ".wav"
    if file.Exists(key, "DATA") then return key end

    ---@param o number
    ---@return number
    local function u(o) return src:byte(o) + src:byte(o+1)*256 + src:byte(o+2)*65536 + src:byte(o+3)*16777216 end
    local pos, fmtChunk, dataOff, dataLen, rate, channels, bits = 13, nil, nil, nil, 0, 0, 0
    while pos + 8 <= #src do
        local id, size = src:sub(pos, pos + 3), u(pos + 4)
        if id == "fmt " then
            fmtChunk = src:sub(pos, pos + 8 + size - 1)
            channels = src:byte(pos + 10) + src:byte(pos + 11) * 256
            rate = u(pos + 12)
            bits = src:byte(pos + 22) + src:byte(pos + 23) * 256
        elseif id == "data" then
            dataOff, dataLen = pos + 8, size
        end
        pos = pos + 8 + size + (size % 2)
    end
    if not (fmtChunk and dataOff and dataLen and rate > 0 and bits > 0 and channels > 0) then return nil end

    local frameBytes = (bits / 8) * channels
    local body = src:sub(dataOff + math.floor(from * rate) * frameBytes, dataOff + dataLen - 1)
    if #body < frameBytes then return nil end
    ---@param v number
    ---@return string
    local function n(v)
        return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256,
            math.floor(v / 16777216) % 256)
    end
    file.CreateDir("doors_loopcache")
    file.Write(key, "RIFF" .. n(4 + #fmtChunk + 8 + #body) .. "WAVE" .. fmtChunk .. "data" .. n(#body) .. body)
    return file.Exists(key, "DATA") and key or nil
end

---@class doors_managed_sound
---@field intro IGModAudioChannel? the original file, playing the part before the loop marker; handed over to chan and dropped
---@field xfade number? progress 0-1 of the intro handing over to the loop
---@field chan IGModAudioChannel? nil while the async load is still in flight
---@field owner Entity?
---@field tag string?
---@field base number caller's max volume (the EmitSound volume equivalent)
---@field volume number current applied volume
---@field ent Entity? source entity for distance falloff (offset applied in its local space)
---@field pos Vector? fixed world source position for falloff (used when ent is not set)
---@field offset Vector? local offset from ent for the source position (like a relative EmitSound pos)
---@field level number? SNDLVL for distance falloff (needs a source: ent or pos)
---@field last_pos Vector? last resolved source position; the pin target when ent teleports or vanishes
---@field pin_on_jump number? see doors_sound_opts
---@field attach Entity? see doors_sound_opts
---@field attach_dist number distance from pos at which attach takes over as the source
---@field occ number? smoothed occlusion gain, eased toward the blocked/clear line-of-sight each frame
---@field omni boolean true for a stereo .wav - Source plays it omnidirectional (mono, no pan, unobscured)
---@field sp_paused boolean? true while parked by the SP-pause watcher
---@field stopped boolean
---@field loop boolean? repeats until stopped
---@field loop_start number seconds into the file its loop begins, 0 for a plain whole-file loop
---@field body IGModAudioChannel? the trimmed loop body, waiting for the intro to hand over to it
---@field fade_to number? volume being faded toward
---@field fade_left number? seconds of fade remaining
---@field stop_when_faded boolean? stop the sound once the running fade finishes
---@field rate number current playback rate, 1 = the file's own pitch
---@field rate_to number? playback rate being eased toward
---@field rate_ease number? seconds the rate ease takes to close most of the gap
local MANAGED = {}
MANAGED.__index = MANAGED

Doors.ActiveManagedSounds = Doors.ActiveManagedSounds or {} ---@type doors_managed_sound[]

---@param handle doors_managed_sound
local function drop(handle)
    handle.chan = nil
    table.RemoveByValue(Doors.ActiveManagedSounds, handle)
end

-- world position the falloff is measured from: ent (+ local offset), or a fixed pos. A followed entity
-- that teleports (pin_on_jump) or is removed leaves the sound pinned at its last position instead of
-- dragging the tail across the map or going global; a pinned sound with an `attach` entity starts
-- following it once it arrives at the pin point.
---@param handle doors_managed_sound
---@return Vector?
local function sourcePos(handle)
    local ent = handle.ent
    if IsValid(ent) then
        local pos = handle.offset and ent:LocalToWorld(handle.offset) or ent:GetPos()
        local last = handle.last_pos
        local jump = handle.pin_on_jump and handle.pin_on_jump * math.max(FrameTime(), 0.001)
        if jump and last and pos:DistToSqr(last) > jump * jump then
            handle.ent = nil
            handle.pos = last
            return last
        end
        handle.last_pos = pos
        return pos
    end
    local attach = handle.attach
    if attach ~= nil and handle.pos and IsValid(attach)
        and attach:GetPos():DistToSqr(handle.pos) <= handle.attach_dist * handle.attach_dist then
        handle.ent = attach
        handle.attach = nil
    end
    return handle.pos or handle.last_pos
end

-- What we need from a .wav's header, read once per path:
--
-- Channel count, because Source plays a positioned STEREO .wav as CHAR_OMNI (S_SetChannelStereo,
-- snd_dma.cpp): omnidirectional, so it's full mono (no left/right panning), distance-attenuated only,
-- and never occluded. A stereo OGG/MP3 is NOT omni (IsStereoWav excludes them) - it spatialises normally.
--
-- And the loop point, because the engine loops a .wav from the marker its author baked in (a `smpl`
-- loop or a `cue ` point), not from the start. Most are marked at sample 0, which is a plain whole-file
-- loop, but an asset can open with an intro and loop only the part after it - and BASS's own looping
-- always wraps to 0, which would replay that intro every cycle. loopStart lets the caller correct it.
--
-- Chunks are walked rather than read at canonical offsets, so a file with extra chunks (LIST/fact/JUNK)
-- before `fmt ` still reads correctly.
---@param data string
---@return number? channels nil if not a parseable WAV
---@return number? loopStartSamples nil if the file carries no loop marker
---@return number? sampleRate
local function wavInfo(data)
    if #data < 16 or data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then return nil end
    ---@param o number
    ---@return number
    local function u32(o)
        return data:byte(o) + data:byte(o+1)*256 + data:byte(o+2)*65536 + data:byte(o+3)*16777216
    end
    local channels, rate, loopStart
    local pos = 13 -- first chunk id (byte 13 = file offset 12)
    while pos + 8 <= #data do
        local id, size = data:sub(pos, pos + 3), u32(pos + 4)
        local body = pos + 8
        if id == "fmt " and body + 11 <= #data then
            channels = data:byte(body + 2) + data:byte(body + 3) * 256 -- audioFormat(2), then channels(2)
            rate = u32(body + 4)
        elseif id == "smpl" and body + 35 <= #data then
            local loops = u32(body + 28)
            if loops > 0 and body + 47 <= #data then
                loopStart = u32(body + 44) -- first loop's dwStart
            end
        elseif id == "cue " and body + 3 <= #data then
            local n = u32(body)
            -- lowest cue offset; a marker at 0 is the common whole-file case
            for i = 0, math.min(n, 64) - 1 do
                local off = body + 4 + i * 24 + 20 -- dwSampleOffset within the cue point
                if off + 3 <= #data then
                    local s = u32(off)
                    loopStart = loopStart and math.min(loopStart, s) or s
                end
            end
        end
        pos = body + size + (size % 2) -- chunks are word-aligned
    end
    return channels, loopStart, rate
end

-- How long an intro takes to hand over to the looping body. Its job is to leave no hard boundary for a
-- late frame to miss, so it stays a fade even at a bad frame rate; much below this it collapses into a
-- single step and becomes a splice again. It doubles as the threshold for bothering at all: an intro
-- shorter than its own handover would never be heard, and those markers are encoder artefacts rather
-- than authored intros anyway.
local HANDOVER = 0.15

---@class doors_wav_header
---@field omni boolean stereo .wav, which Source plays omnidirectional
---@field loop_start number seconds into the file that its baked-in loop marker starts at, 0 if none

local wavCache = {} ---@type table<string, doors_wav_header>
---@param path string sound path relative to sound/
---@return doors_wav_header
local function wavHeader(path)
    local cached = wavCache[path]
    if cached then return cached end
    local info = { omni = false, loop_start = 0 }
    if string.EndsWith(path:lower(), ".wav") then
        local data = file.Read("sound/" .. path, "GAME")
        if data == nil then
            -- unreadable .wav (e.g. a mount file.Read can't reach): assume stereo, since almost every
            -- one is - so it defaults to omni, matching what Source does with a stereo wav
            info.omni = true
        else
            local channels, loopStart, rate = wavInfo(data)
            info.omni = channels == 2
            if loopStart and rate and rate > 0 then
                local secs = loopStart / rate
                -- too short to outlast its own handover: treat it as a whole-file loop, which is the
                -- simple path and what such a marker means in practice
                info.loop_start = secs > HANDOVER and secs or 0
            end
        end
    end
    wavCache[path] = info
    return info
end

-- Source's stereo spatialisation, ported from CAudioDeviceBase::SpatializeChannel + GetSpeakerVol
-- (engine/audio/snd_dev_common.cpp). Returns the per-side gains (lf, rf, 0-1) Source applies to a
-- positioned sound's left/right channels: a nonlinear power-1.5 speaker crossfade, quieter rear (rear
-- folded in at 0.75), and a pitch->mono centring for sounds far above/below. Config-dependent -
-- snd_surround_speakers 0 = headphone (gentle), else the 2-speaker 4->2 fold (the usual desktop default).
-- Applied on a stereo channel as SetVolume(gain * max(lf,rf)) + SetPan((rf-lf)/max), this reproduces
-- Source's per-side leftvol/rightvol exactly - matching both the pan and the ~0.646 centre envelope.
local snd_surround = GetConVar("snd_surround_speakers")
local SND_VOLCURVE = 1.5

-- one speaker's contribution (GetSpeakerVol). cspeaker 2 = opposing headphone pair, 4 = the 90-deg
-- surround/stereo speakers; `mono` (0-1) fades the speaker toward the centred distribution target.
---@param yaw number
---@param speakerYaw number
---@param mono number
---@param cspeaker number
---@param rear boolean?
---@return number
local function speakerVol(yaw, speakerYaw, mono, cspeaker, rear)
    local adif = math.abs(yaw - speakerYaw)
    if adif > 180 then adif = 360 - adif end
    local scale
    if cspeaker == 2 then
        scale = 1 - (adif / 180) ^ SND_VOLCURVE
    elseif adif >= 90 then
        scale = 0
    else
        scale = 1 - (adif / 90) ^ SND_VOLCURVE
    end
    local target = (cspeaker ~= 2 and rear) and 0 or 0.9
    return scale + (target - scale) * mono
end

-- Source's left/right per-side gains (0-1) for a source at `pos`, from the yaw/pitch to it. `radius` is
-- the emitter's own size (ent:GetModelRadius(), what Source uses): inside it the sound blends to mono.
---@param pos Vector
---@param radius number source radius in units; 0 = point source (no mono collapse)
---@return number lf
---@return number rf
local function spatialize(pos, radius)
    local dir = pos - EyePos()
    local dist = dir:Length()
    if dist < 1 then return 0.9, 0.9 end
    local ang = dir:Angle()
    local right = EyeAngles():Right()
    local yaw = (ang.yaw - Vector(right.x, right.y, 0):Angle().yaw) % 360
    -- pitch (folded to 0-90 above/below horizontal) collapses toward mono past 45 degrees
    local pitch = ang.pitch
    if pitch < 0 then pitch = pitch + 360 end
    if pitch > 180 then pitch = 360 - pitch end
    if pitch > 90 then pitch = 90 - (pitch - 90) end
    local mono = pitch > 45 and math.Clamp((pitch - 45) / 45, 0, 1) or 0
    -- radius mono collapse: a positioned sound reads as mono once the listener is within the emitter's
    -- radius, ramping from stereo at the rim to full mono at half-radius (so a large interior's demat,
    -- whose origin you stand inside, barely pans - matching Source rather than hard-panning by position).
    if radius > 0 and dist < radius then
        local interval = radius * 0.5
        mono = math.Clamp(mono + 1 - math.max(dist - interval, 0) / interval, 0, 1)
    end
    if snd_surround and snd_surround:GetInt() == 0 then
        return speakerVol(yaw, 180, mono, 2), speakerVol(yaw, 0, mono, 2)
    end
    local rf = speakerVol(yaw, 45, mono, 4)
    local lf = speakerVol(yaw, 135, mono, 4)
    local rr = speakerVol(yaw, 315, mono, 4, true)
    local lr = speakerVol(yaw, 225, mono, 4, true)
    return math.Clamp(lf + lr * 0.75, 0, 1), math.Clamp(rf + rr * 0.75, 0, 1)
end

-- Master SFX volume: BASS channels bypass the `volume` convar that EmitSound obeys, so fold it in for
-- parity - otherwise a lowered SFX slider wouldn't quieten these sounds like it did the old ones.
local volumeConVar = GetConVar("volume")

-- Source only muffles a sound when WORLD geometry blocks the straight path to it: SND_GetGainObscured
-- traces CTraceFilterWorldOnly (map brushes only), so props and other entities never occlude - including
-- an interior's own floor, even though the origin sits below it. So trace world-only (ignore every entity)
-- and ease the gain toward the obscured level when a brush blocks. This muffles the exterior copy behind a
-- real wall like the engine does, and is a no-op inside the geometry-free interior void. (Source softens
-- occlusion over a 4-point radius; a single binary block is close enough and doesn't compound stacked walls.)
local snd_obscured = GetConVar("snd_obscured_gain_dB")
local MASK_BLOCK_AUDIO = bit.bor(CONTENTS_SOLID, CONTENTS_MOVEABLE, CONTENTS_WINDOW) --[[@as MASK]]
local function ignoreEntities() return false end
---@param handle doors_managed_sound
---@param pos Vector
---@return number
local function occlusion(handle, pos)
    local blocked = util.TraceLine({ start = EyePos(), endpos = pos, mask = MASK_BLOCK_AUDIO, filter = ignoreEntities }).Hit
    local target = blocked and (snd_obscured and 10 ^ (snd_obscured:GetFloat() / 20) or 0.73) or 1
    if handle.occ == nil then
        handle.occ = target
    else
        handle.occ = Lerp(FrameTime() * 8, handle.occ, target)
    end
    return handle.occ
end

-- Source scales every sound by its mix-group volume (MXR_GetVolFromMixGroup) before mixing. Our BASS
-- channel bypasses the mixer, so fold the group volume in for parity. An addon's own SFX carry no special
-- name or classname, so they fall through Default_Mix's rules to the catch-all "All" group (0.72). GMod
-- exposes no live mixer to Lua and a map's soundscape can pick a different mixer, so this is the
-- default-mix constant rather than a per-frame read - right for the common case, and what a plain
-- EmitSound of these sounds would have played at anyway.
local SOURCE_MIXER_GAIN = 0.72

-- volume for this frame: base * SNDLVL distance gain * occlusion * mixer * master.
-- Omni (stereo-wav) sounds are unattenuated by direction and never obscured, so they skip occlusion.
---@param handle doors_managed_sound
---@return number
local function targetVolume(handle)
    local gain = 1
    local pos = sourcePos(handle)
    if pos then
        if handle.level then
            gain = sndLevelGain(EyePos():Distance(pos), handle.level)
        end
        if not handle.omni then
            gain = gain * occlusion(handle, pos)
        end
    end
    return handle.base * gain * SOURCE_MIXER_GAIN * (volumeConVar and volumeConVar:GetFloat() or 1)
end

local OMNI_ENVELOPE = 0.9   -- GetSpeakerVol's fully-mono target per front speaker (both sides equal)
-- Apply this frame's level and pan. targetVolume is Source's pre-spatialisation scalar gain; the
-- spatialiser then splits it into the left/right the engine would produce, mapped onto a stereo BASS
-- channel via SetVolume (the louder side) + SetPan (the ratio between them). While an intro is handing
-- over to its loop both channels are live, so each gets the same placement at its share of the volume -
-- an equal-power split, which holds the loudness steady across the handover.
---@param handle doors_managed_sound
local function applyGain(handle)
    local scalar = targetVolume(handle)
    local pos = sourcePos(handle)
    local pan = 0
    if pos and handle.omni then
        -- CHAR_OMNI: mono, both channels equal, no pan - only the distance gain varies
        handle.volume = scalar * OMNI_ENVELOPE
    elseif pos then
        local radius = IsValid(handle.ent) and handle.ent:GetModelRadius() or 0
        local lf, rf = spatialize(pos, radius)
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

function MANAGED:IsValid()
    return IsValid(self.chan)
end

function MANAGED:IsPlaying()
    return IsValid(self.chan) and self.chan:GetState() == GMOD_CHANNEL_PLAYING
end

-- BASS has a slide of its own, but GMod doesn't expose it, so a fade is run from the Think loop below -
-- the same place the distance gain is already rewritten every frame, so it costs nothing extra.
---@param volume number
---@param time number? seconds to fade over; omitted or 0 applies it immediately
function MANAGED:SetVolume(volume, time)
    if time and time > 0 then
        self.fade_to = volume
        self.fade_left = time
        return
    end
    self.fade_to, self.fade_left, self.stop_when_faded = nil, nil, nil
    self.base = volume
    -- go through the gain path rather than writing the channel: the caller's volume is the pre-distance
    -- one, so writing it straight to the channel would play a far-off sound at full volume
    applyGain(self)
end

-- Fade out and stop, for a loop that shouldn't just cut off.
---@param time number seconds
function MANAGED:FadeOut(time)
    if not (time and time > 0) then return self:Stop() end
    self.fade_to = 0
    self.fade_left = time
    self.stop_when_faded = true
end

-- Playback rate doubles as pitch, the same way Source's pitch does - both resample, so speed and pitch
-- move together. `ease` matches the engine's own pitch glide: a target this eases toward rather than
-- snaps to, which keeps a per-frame target (flight speed, doppler) from arriving as steps.
---@param pitch number percent, 100 = the file's own pitch
---@param ease number? seconds to glide over; omitted or 0 applies it immediately
function MANAGED:SetPitch(pitch, ease)
    local rate = math.max(pitch, 1) / 100
    if ease and ease > 0 then
        self.rate_to = rate
        self.rate_ease = ease
        return
    end
    self.rate_to, self.rate_ease = nil, nil
    self.rate = rate
    if IsValid(self.chan) then
        self.chan:SetPlaybackRate(rate)
    end
end

function MANAGED:Stop()
    self.stopped = true
    if IsValid(self.chan) then
        self.chan:Stop()
    end
    -- an intro still handing over to its loop has to go too
    if IsValid(self.intro) then
        self.intro:Stop()
    end
    self.intro = nil
    drop(self)
end

-- EmitSound's default sound level; the SNDLVL_* names aren't Lua globals, so 75
local DEFAULT_SNDLVL = 75

-- SP-pause watcher state (the PreRender hook at the bottom): true while the game is paused.
-- SinglePlayer can't change within a session, so read it once instead of per frame.
local SINGLEPLAYER = game.SinglePlayer()
local sp_paused = false
local last_think_frame = 0

---@param opts doors_sound_opts
---@return doors_managed_sound
local function playManaged(opts)
    local header = wavHeader(opts.path)
    ---@type doors_managed_sound
    local handle = setmetatable({
        owner = opts.owner,
        tag = opts.tag,
        base = opts.volume or 1,
        volume = opts.volume or 1,
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
        rate = 1,
        stopped = false,
    }, MANAGED)
    table.insert(Doors.ActiveManagedSounds, handle)

    -- A loop whose file opens with an intro plays that intro from the original and hands over to a
    -- trimmed copy that BASS can loop whole-file. Both are loaded before either is heard, so the body
    -- is ready to start on the exact frame the handover begins.
    local bodyPath = handle.loop and handle.loop_start > 0
        and loopBodyFile(opts.path, handle.loop_start) or nil

    ---@param chan IGModAudioChannel
    ---@param canLoop boolean false while this channel is only playing an intro in
    local function start(chan, canLoop)
        handle.chan = chan
        if handle.loop and canLoop then chan:EnableLooping(true) end
        if handle.rate ~= 1 then chan:SetPlaybackRate(handle.rate) end
        applyGain(handle)
        chan:Play()
        -- the async load can complete mid-pause; start parked so it doesn't play into the pause
        if sp_paused then
            chan:Pause()
            handle.sp_paused = true
        end
    end

    -- Stereo, like Source: a positioned stereo sound keeps its channels, each scaled by that side's
    -- spatialisation weight (not summed to mono). noblock fully loads so there's no block-stream hitch.
    -- noplay keeps a channel at its first sample until it is wanted - PlayFile starts it otherwise.
    sound.PlayFile("sound/" .. opts.path, "noblock", function(chan)
        if handle.stopped then
            -- stopped before the load finished (e.g. an interrupt raced the load)
            if IsValid(chan) then chan:Stop() end
        elseif IsValid(chan) then
            -- with a body to hand over to, this channel is only playing the intro, so it must not loop
            start(chan, bodyPath == nil)
        else
            drop(handle)
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

---@api
---@param opts doors_sound_opts
---@return doors_managed_sound? handle to a resumable sound, so callers can stop or track that exact sound
function Doors:PlaySound(opts)
    -- a loop always needs the managed channel: it plays long enough for the listener to cross the void
    if opts.resumable or opts.loop then
        return playManaged(opts)
    end
    playNative(opts)
end

-- Only resumable sounds can be stopped as a group: the engine's own sounds are fire-and-forget once
-- started, so a caller that needs to cut one short stops it through the entity it plays from.
---@api
---@param owner Entity
---@param tag string?
function Doors:StopSounds(owner, tag)
    local list = Doors.ActiveManagedSounds
    for i = #list, 1, -1 do
        local handle = list[i]
        if handle.owner == owner and (tag == nil or handle.tag == tag) then
            handle:Stop()
        end
    end
end

net.Receive("Doors-Sound", function()
    local path = net.ReadString()
    local owner = net.ReadEntity()
    local tag = net.ReadString()
    local volume = net.ReadFloat()
    local ent = net.ReadEntity()
    local pos = net.ReadBool() and net.ReadVector() or nil
    local offset = net.ReadBool() and net.ReadVector() or nil
    local level = net.ReadBool() and net.ReadUInt(8) or nil
    local resumable = net.ReadBool()
    Doors:PlaySound({
        path = path,
        owner = IsValid(owner) and owner or nil,
        tag = tag ~= "" and tag or nil,
        volume = volume,
        ent = IsValid(ent) and ent or nil,
        pos = pos,
        offset = offset,
        level = level,
        resumable = resumable,
    })
end)

net.Receive("Doors-SoundStop", function()
    local owner = net.ReadEntity()
    local tag = net.ReadString()
    if not IsValid(owner) then return end
    Doors:StopSounds(owner, tag ~= "" and tag or nil)
end)

-- Advance a running volume fade. Linear over the requested time, stepped by frame rather than clock so
-- it freezes with the game like the sound itself does.
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

-- Ease the playback rate toward its target instead of snapping, so a per-frame pitch target (flight
-- speed plus doppler, both jittery) doesn't arrive as steps. Exponential, so it closes most of the gap
-- within the requested time and settles without overshoot.
---@param handle doors_managed_sound
---@param chan IGModAudioChannel
local function stepRate(handle, chan)
    local target = handle.rate_to
    if not target then return end
    local ease = handle.rate_ease or 0.1
    handle.rate = Lerp(math.min(FrameTime() / ease, 1), handle.rate, target)
    if math.abs(handle.rate - target) < 0.001 then
        handle.rate = target
        handle.rate_to = nil
    end
    chan:SetPlaybackRate(handle.rate)
end

-- Play the intro in, then hand over to the looping body. Both channels are already loaded, so the body
-- starts on the frame the handover begins and the two are crossfaded across it (applyGain splits the
-- volume between them). Crossfading rather than cutting is what makes this safe: there is no instant to
-- miss, so a late frame shifts the blend slightly instead of leaving a gap. During the fade the intro
-- is playing the samples before the marker and the body the samples after, so they are consecutive
-- audio - overlapping the *same* audio would comb-filter.
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

hook.Add("Think", "doors_managed_sounds", function()
    last_think_frame = FrameNumber()
    local list = Doors.ActiveManagedSounds
    for i = #list, 1, -1 do
        local handle = list[i]
        if handle.owner ~= nil and not IsValid(handle.owner) then
            -- owner deleted: stop, like the entity's own EmitSounds would have
            handle:Stop()
        else
            stepHandover(handle)
            local chan = handle.chan
            if chan ~= nil then
                if not IsValid(chan) or chan:GetState() == GMOD_CHANNEL_STOPPED then
                    drop(handle)
                else
                    stepFade(handle)
                    if not handle.stopped then -- a fade can end in a stop, which drops the handle
                        stepRate(handle, chan)
                        applyGain(handle)
                    end
                end
            end
        end
    end
end)

-- SP pause parity: native EmitSounds freeze with the engine but BASS plays in real time, so park the
-- channels while the game is paused. No pause hook or getter exists, but render hooks keep running at
-- full frame rate through a pause while Think freezes completely - so render frames passing with no
-- Think detect the transition within ~2 frames. Singleplayer only: in multiplayer a Think stall is net
-- lag, during which native sounds keep playing, so pausing here would create a divergence, not fix one.
hook.Add("PreRender", "doors_managed_sounds_pause", function()
    if not SINGLEPLAYER or last_think_frame == 0 then return end
    local now_paused = FrameNumber() - last_think_frame >= 2
    if now_paused == sp_paused then return end
    sp_paused = now_paused
    for _, handle in ipairs(Doors.ActiveManagedSounds) do
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
