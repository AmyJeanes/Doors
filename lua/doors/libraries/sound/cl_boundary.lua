---@class doors_sound_module
---@field tuning doors_sound_tuning
---@field tuning_defaults doors_sound_tuning
---@field transition_floor number
---@field resolve fun(handle: doors_managed_sound): doors_sound_resolution
---@field new_resolution fun(): doors_sound_resolution

---@class doors_managed_sound
---@field last_pos Vector? last resolved source position; the pin target when ent teleports or vanishes
---@field pair string? counterpart key, scoped to owner
---@field through_doors number? author's override on the counterpart rule
---@field cp_weight number? smoothed counterpart weight as a power, square-rooted into a volume downstream
---@field cp_last number? the weight last settled on while a counterpart existed, held once it ends
---@field cp_hold boolean? hold the level this was at rather than glide, while it yields to its counterpart
---@field res doors_sound_resolution where the sound is heard from this frame, and what a doorway did to it
---@field res_frame number frame the resolution was last computed on
---@field heal_from number? gain the sound was at when it last changed space, glided away from
---@field heal_left number seconds of that glide remaining
---@field heal_span number seconds that glide runs for in total
---@field last_space gmod_door_interior? space the sound was in last frame, nil for the open world
---@field last_listener_space gmod_door_interior? space the listener was in last frame
---@field last_gain number? last frame's gain, so a space change can be captured as a step

local Sound = Doors.Sound

--------------------------------------------------------------------------------------------------
-- Tuning
--------------------------------------------------------------------------------------------------

---@class doors_sound_tuning
---@field closed number aperture with the door fully shut; fully open is 1 and is not a setting
---@field curve number exponent on openness, so a door barely cracked does not jump to nearly open
---@field falloff number dB per 1000u, for each halving of the doorway below SIZE_NEUTRAL
---@field aim number how much the opening throws its sound outward: 0 every way, 1 silent behind it
local TUNING_DEFAULTS = {
    closed  = 0.250,
    curve   = 1.00,
    falloff = 25.00,
    aim     = 0.50,
}

Sound.tuning = table.Copy(TUNING_DEFAULTS) ---@type doors_sound_tuning
Sound.tuning_defaults = TUNING_DEFAULTS ---@type doors_sound_tuning

local SIZE_NEUTRAL = 16384
local LOG2 = math.log(2)

local TRANSITION_FLOOR = 0.5
Sound.transition_floor = TRANSITION_FLOOR

local VIEW_TRANSITION = 0.15

local transitionConVar = CreateClientConVar("doors_sound_transition", "0", false, false,
    "Seconds a sound takes to settle after the listener moves between spaces, or 0 for the default")

---@return number
local function moveTransition()
    local v = transitionConVar:GetFloat()
    return v > 0 and v or TRANSITION_FLOOR
end

local GAIN_FLOOR = 1e-5

--------------------------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------------------------

---@param ent Entity
---@param portal doors_portal_side
---@return Vector
local function mouthNormal(ent, portal)
    return ent:LocalToWorldAngles(portal.ang):Forward()
end

---@param ent Entity
---@param portal doors_portal_side
---@param p Vector
---@return Vector
local function mouthPoint(ent, portal, p)
    local centre = ent:LocalToWorld(portal.pos)
    local ang = ent:LocalToWorldAngles(portal.ang)
    local right, up = ang:Right(), ang:Up()
    local d = p - centre
    return centre
        + right * math.Clamp(d:Dot(right), -portal.width / 2, portal.width / 2)
        + up * math.Clamp(d:Dot(up), -portal.height / 2, portal.height / 2)
end

---@class doors_sound_face
---@field ent Entity the interior or exterior the doorway belongs to
---@field portal doors_portal_side

---@param int gmod_door_interior
---@return doors_sound_face? interior
---@return doors_sound_face? exterior
---@return number area
local function faces(int)
    local ext = int.exterior
    if not IsValid(ext) then return nil, nil, 0 end
    local ip, ep = int:GetDoorway(), ext:GetDoorway()
    if not ip or not ep then return nil, nil, 0 end
    return { ent = int, portal = ip }, { ent = ext, portal = ep },
        math.min(ip.width * ip.height, ep.width * ep.height)
end

--------------------------------------------------------------------------------------------------
-- Spaces
--------------------------------------------------------------------------------------------------

---@param ent Entity?
---@param pos Vector
---@return gmod_door_interior?
local function spaceOf(ent, pos)
    for _ = 1, 16 do -- cap against a parent cycle
        if not IsValid(ent) then break end
        ---@cast ent Entity
        if ent.DoorInterior then return ent --[[@as gmod_door_interior]] end
        if ent.DoorExterior then
            local inside = ent.insideof
            return IsValid(inside) and inside or nil
        end
        ent = ent:GetParent()
    end
    for int in pairs(Doors:GetInteriors()) do
        if IsValid(int) and int:PositionInside(pos) then return int end
    end
    return nil
end

---@class doors_listener_state
---@field frame number
---@field space gmod_door_interior? the space the camera is in
---@field body gmod_door_interior? the space its owner's body is in
---@field body_changed number RealTime the body last changed space
---@field eye Vector? the camera position `space` was resolved from

local BODY_SETTLE = 0.25

local listenerState = { frame = -1, body_changed = -math.huge } ---@type doors_listener_state

-- MainEyePos(), never EyePos(): the latter is only meaningful inside a render pass, and this runs
-- from Think, where it freezes at the position of the last one.
---@return gmod_door_interior?
local function getListenerSpace()
    local ply = LocalPlayer()
    local body = IsValid(ply) and ply.doori or nil
    if body ~= nil and not IsValid(body) then body = nil end
    local eye = MainEyePos()

    -- Keyed on the camera and body too, not the frame alone: crossing a doorway teleports the camera
    -- between two of these calls, and a stale answer drops the doorway out of the path entirely.
    if listenerState.frame == FrameNumber() and listenerState.body == body
        and listenerState.eye == eye then
        return listenerState.space
    end
    listenerState.frame = FrameNumber()
    listenerState.eye = eye

    local space
    if body and body:PositionInside(eye) then
        space = body
    else
        space = spaceOf(nil, eye)
    end

    if body ~= listenerState.body then
        listenerState.body = body
        listenerState.body_changed = RealTime()
    end
    listenerState.space = space
    return space
end

---@class doors_openness_state
---@field frame number
---@field value number

local opennessState = setmetatable({}, { __mode = "k" }) ---@type table<gmod_door_interior, doors_openness_state>

---@param int gmod_door_interior
---@return number
local function openness(int)
    local state = opennessState[int]
    local ext = int.exterior
    local raw = IsValid(ext) and math.Clamp(ext:GetDoorOpenness(), 0, 1) or 1
    if not state then
        state = { frame = FrameNumber(), value = raw }
        opennessState[int] = state
    elseif state.frame ~= FrameNumber() then
        state.frame = FrameNumber()
        state.value = math.Approach(state.value, raw, FrameTime() / TRANSITION_FLOOR)
    end
    return state.value
end

--------------------------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------------------------

---@class doors_sound_resolution
---@field pos Vector? where the sound is heard from - the doorway itself when it comes through one
---@field dist number distance from the listener along the path the sound travels
---@field gain number everything the doorway does to it, 1 when there is no doorway in the path
---@field applied number the finished attenuation: the doorway, the distance and any glide, together
---@field int gmod_door_interior? the boundary in the path, nil when listener and sound share a space
---@field inside boolean the listener is in `int` rather than outside it
---@field emitter Vector? where the sound actually is, as opposed to where it is heard from
---@field source doors_sound_face? the doorway the sound radiates into
---@field listener doors_sound_face? the doorway it reaches the listener from
---@field normal Vector? which way that doorway faces
---@field d1 number the sound to its own doorway
---@field d2 number the listener's doorway to the listener
---@field area number the tighter doorway's area in square units
---@field openness number
---@field volume number the consumer's own scalar for sound crossing this boundary
---@field aperture number flat gain from how open the door is
---@field db_per_1000 number how fast this doorway's size makes the sound fall off past the mouth
---@field extra number the extra falloff past the mouth, at this distance
---@field vol_extra number the consumer's cross-boundary volume as a falloff, 1 at the mouth
---@field facing number -1 directly behind the doorway, 1 head on
---@field directivity number
---@field healing number 0-1 of a captured space change still to fade
---@field space gmod_door_interior? the space the sound itself is in, nil in the open world
---@field counterpart number gain from the counterpart rule, 1 when this sound has no counterpart

---@return doors_sound_resolution
local function newResolution()
    return { dist = 0, gain = 1, applied = 1, inside = false, d1 = 0, d2 = 0, area = 0, openness = 1,
        volume = 1, aperture = 1, db_per_1000 = 0, extra = 1, vol_extra = 1, facing = 1, directivity = 1,
        healing = 0, counterpart = 1 }
end
Sound.new_resolution = newResolution

--------------------------------------------------------------------------------------------------
-- Counterparts
--------------------------------------------------------------------------------------------------

---@class doors_sound_pair_index
---@field frame number
---@field groups table<string, doors_managed_sound[]>

local pairIndex = { frame = -1, groups = {} } ---@type doors_sound_pair_index

local function rebuildPairIndex()
    pairIndex.frame = FrameNumber()
    local groups = {}
    for _, h in ipairs(Sound.active) do
        if h.pair ~= nil and h.patch == nil and IsValid(h.owner) and not h.stopped then
            local id = tostring(h.owner:EntIndex()) .. "\0" .. h.pair
            local g = groups[id]
            if g then g[#g + 1] = h else groups[id] = { h } end
        end
    end
    pairIndex.groups = groups
end

---@param handle doors_managed_sound
---@param space gmod_door_interior?
---@param listenerSpace gmod_door_interior?
---@return number, boolean
local function counterpartGain(handle, space, listenerSpace)
    local key = handle.pair
    if key == nil or not IsValid(handle.owner) then return 1, true end

    if pairIndex.frame ~= FrameNumber() then rebuildPairIndex() end

    local id = tostring(handle.owner:EntIndex()) .. "\0" .. key
    local group = pairIndex.groups[id]
    if group == nil or not table.HasValue(group, handle) then
        rebuildPairIndex()
        group = pairIndex.groups[id]
    end
    if group == nil or #group < 2 then
        local held = handle.cp_last
        if held then return held, true end
        return 1, false -- no counterpart in existence yet: nothing to weigh against
    end

    local weight
    if space == listenerSpace then
        weight = 1
    else
        local anyNear = false
        ---@type doors_managed_sound?
        local worldSide = nil
        for _, h in ipairs(group) do
            local hs = h.res.space
            if hs == listenerSpace then
                anyNear = true
                break
            end
            if hs == nil and worldSide == nil then worldSide = h end
        end
        if not anyNear and (worldSide == nil or worldSide == handle) then
            weight = 1
        else
            local through = handle.through_doors or 0
            weight = through * through
        end
    end
    handle.cp_last = weight
    return weight, true
end

--------------------------------------------------------------------------------------------------
-- resolve
--------------------------------------------------------------------------------------------------

---@param handle doors_managed_sound
---@return Vector?
local function sourcePos(handle)
    local attach = handle.attach
    if attach ~= nil and handle.pos and not IsValid(handle.ent) and IsValid(attach)
        and attach:GetPos():DistToSqr(handle.pos) <= handle.attach_dist * handle.attach_dist then
        handle.ent, handle.attach, handle.pos = attach, nil, nil
    end
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
    return handle.pos or handle.last_pos
end

---@param handle doors_managed_sound
---@return doors_sound_resolution
local function resolve(handle)
    local res = handle.res
    if handle.res_frame == FrameNumber() then return res end
    handle.res_frame = FrameNumber()

    local pos = sourcePos(handle)
    res.emitter, res.pos = pos, pos
    res.int, res.source, res.listener, res.normal, res.space = nil, nil, nil, nil, nil
    res.inside = false
    res.gain, res.d1, res.d2, res.area = 1, 0, 0, 0
    res.openness, res.volume, res.aperture, res.facing, res.directivity = 1, 1, 1, 1, 1
    res.db_per_1000, res.extra, res.vol_extra, res.counterpart = 0, 1, 1, 1
    res.dist = pos and MainEyePos():Distance(pos) or 0
    if not pos then
        res.applied, res.healing = 1, 0
        return res
    end

    local listenerSpace = getListenerSpace()
    local space = spaceOf(handle.ent, pos)
    res.space = space

    local int = space ~= listenerSpace and (space or listenerSpace) or nil
    local intFace, extFace, area = nil, nil, 0
    if int then intFace, extFace, area = faces(int) end

    if int and intFace and extFace then
        local inside = int ~= space
        local source = inside and extFace or intFace
        local listener = inside and intFace or extFace
        local mouth = mouthPoint(listener.ent, listener.portal, MainEyePos())
        local d1 = pos:Distance(mouthPoint(source.ent, source.portal, pos))
        local d2 = MainEyePos():Distance(mouth)

        local tuning = Sound.tuning
        local open = openness(int)
        local aperture = tuning.closed + (1 - tuning.closed) * open ^ tuning.curve

        -- Divided rather than math.log(x, 2): the base argument is a 5.2 signature the 32-bit branch's
        -- LuaJIT ignores, silently answering a natural log and making this term 31% weak.
        local halvings = math.max(0, math.log(SIZE_NEUTRAL / math.max(area, 1)) / LOG2)
        local dbPer1000 = tuning.falloff * halvings
        local extra = 10 ^ (-(dbPer1000 * d2 / 1000) / 20)

        local normal = mouthNormal(listener.ent, listener.portal)
        local facing = d2 > 1 and normal:Dot((MainEyePos() - mouth):GetNormalized()) or 1
        local directivity = 1 - tuning.aim * 0.5 * (1 - facing)

        res.int, res.inside = int, inside
        res.source, res.listener, res.normal = source, listener, normal

        local volume = math.Clamp(int.exterior:GetCrossBoundaryVolume(), 0, 1)
        local volExtra = volume > 0 and volume ^ (d2 / 1000) or 0

        res.d1, res.d2, res.area = d1, d2, area
        res.openness, res.volume, res.aperture = open, volume, aperture
        res.db_per_1000, res.extra, res.vol_extra = dbPer1000, extra, volExtra
        res.facing, res.directivity = facing, directivity
        res.gain = aperture * extra * directivity * volExtra
        res.pos, res.dist = mouth, d1 + d2
    end

    local gain = res.gain
    if handle.level then gain = gain * Sound.distance_gain(res.dist, handle.level) end
    gain = math.max(gain, GAIN_FLOOR)
    local weight, settled = counterpartGain(handle, space, listenerSpace)
    local inPair = handle.pair ~= nil and settled
    if handle.last_space ~= space or handle.last_listener_space ~= listenerSpace then
        local listenerOnly = handle.last_space == space
        local viewCut = listenerOnly and (RealTime() - listenerState.body_changed) > BODY_SETTLE
        handle.heal_span = viewCut and VIEW_TRANSITION or moveTransition()

        local yielding = inPair and listenerOnly and weight <= 0
        -- spelt out because an `and nil or` cannot express it: `x and nil` is already false
        if inPair and listenerOnly and not yielding then
            handle.heal_from = nil
        else
            handle.heal_from = handle.last_gain -- nil on the first resolve, nothing to glide from
        end
        handle.heal_left = handle.heal_from and handle.heal_span or 0
        handle.cp_hold = yielding
        handle.last_space, handle.last_listener_space = space, listenerSpace
    end

    local healing = 0
    if handle.heal_left > 0 then
        handle.heal_left = handle.heal_left - FrameTime()
        healing = math.max(handle.heal_left, 0) / handle.heal_span
    end
    res.healing = healing
    local from = handle.heal_from
    if handle.cp_hold and healing > 0 and from then
        res.applied = from
    else
        res.applied = (healing > 0 and from) and gain ^ (1 - healing) * from ^ healing or gain
    end
    handle.last_gain = res.applied

    -- Linear, outside the dB glide above: a mix target is absence, which in dB is minus infinity.
    -- Square-rooted because two loops that are not copies sum by power, not amplitude.
    if handle.cp_weight ~= nil then
        handle.cp_weight = math.Approach(handle.cp_weight, weight, FrameTime() / handle.heal_span)
    elseif settled then
        handle.cp_weight = weight
    end
    res.counterpart = math.sqrt(handle.cp_weight or weight)
    res.applied = res.applied * res.counterpart
    return res
end
Sound.resolve = resolve
