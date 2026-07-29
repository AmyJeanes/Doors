---@class doors_sound_module
---@field distance_gain fun(dist: number, level: number): number
---@field spatialize fun(pos: Vector, radius: number): number, number
---@field occlusion fun(handle: doors_managed_sound, pos: Vector): number
---@field mixer_gain number

local Sound = Doors.Sound

--------------------------------------------------------------------------------------------------
-- Distance gain
--------------------------------------------------------------------------------------------------

-- sound_shared.cpp SND_GetGainFromMult. Validated against snd_show's own channel gains at
-- 150/300/600/1200u, matching to 1 part in 255.
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
local function distanceGain(dist, level)
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
Sound.distance_gain = distanceGain

---@api
---@param dist number
---@param level number
---@return number gain
function Doors:DistanceGain(dist, level)
    return distanceGain(dist, level)
end

--------------------------------------------------------------------------------------------------
-- Stereo spatialisation
--------------------------------------------------------------------------------------------------

-- CAudioDeviceBase::SpatializeChannel + GetSpeakerVol (snd_dev_common.cpp). snd_surround_speakers 0
-- is the headphone pair, anything else the 2-speaker 4->2 fold.
local snd_surround = GetConVar("snd_surround_speakers")
local SND_VOLCURVE = 1.5

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

---@param pos Vector
---@param radius number emitter radius in units (ent:GetModelRadius()); 0 = point source
---@return number lf
---@return number rf
local function spatialize(pos, radius)
    local dir = pos - MainEyePos()
    local dist = dir:Length()
    if dist < 1 then return 0.9, 0.9 end
    local ang = dir:Angle()
    -- MainEyeAngles, not EyeAngles: this runs from Think, where EyeAngles() is the last render pass's -
    -- and a doorway on screen makes that the portal's virtual camera.
    local right = MainEyeAngles():Right()
    local yaw = (ang.yaw - Vector(right.x, right.y, 0):Angle().yaw) % 360
    local pitch = ang.pitch
    if pitch < 0 then pitch = pitch + 360 end
    if pitch > 180 then pitch = 360 - pitch end
    if pitch > 90 then pitch = 90 - (pitch - 90) end
    local mono = pitch > 45 and math.Clamp((pitch - 45) / 45, 0, 1) or 0
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
Sound.spatialize = spatialize

--------------------------------------------------------------------------------------------------
-- Occlusion
--------------------------------------------------------------------------------------------------

-- SND_GetGainObscured traces CTraceFilterWorldOnly, so only map brushes muffle a sound and no entity
-- ever does - including an interior's own floor, though the origin sits below it.
local snd_obscured = GetConVar("snd_obscured_gain_dB")
local MASK_BLOCK_AUDIO = bit.bor(CONTENTS_SOLID, CONTENTS_MOVEABLE, CONTENTS_WINDOW) --[[@as MASK]]
local function ignoreEntities() return false end

---@param handle doors_managed_sound
---@param pos Vector
---@return number
local function occlusion(handle, pos)
    local blocked = util.TraceLine({
        start = MainEyePos(), endpos = pos, mask = MASK_BLOCK_AUDIO, filter = ignoreEntities,
    }).Hit
    local target = blocked and (snd_obscured and 10 ^ (snd_obscured:GetFloat() / 20) or 0.73) or 1
    if handle.occ == nil then
        handle.occ = target
    else
        handle.occ = Lerp(FrameTime() * 8, handle.occ, target)
    end
    return handle.occ
end
Sound.occlusion = occlusion

-- Source scales every sound by its mix-group volume before mixing, which a BASS channel bypasses.
-- An addon's own SFX fall through Default_Mix to the catch-all "All" group; GMod exposes no live
-- mixer to Lua, so this is that constant.
Sound.mixer_gain = 0.72
