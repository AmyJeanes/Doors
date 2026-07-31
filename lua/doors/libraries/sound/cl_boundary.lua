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
        if ent.DoorInterior then return ent end
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

---@param int gmod_door_interior
---@return gmod_door_interior? the space this interior's own exterior stands in
local function containerOf(int)
    local ext = int.exterior
    if not IsValid(ext) then return nil end
    local inside = ext.insideof
    return IsValid(inside) and inside or nil
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
-- The doorways in between
--------------------------------------------------------------------------------------------------

---@class doors_sound_hop
---@field int gmod_door_interior
---@field enter boolean the sound enters this interior here, rather than leaving it
---@field area number the tighter of its two doorways, in square units
---@field facing number -1 directly behind the doorway it comes out of, 1 head on
---@field seg number how far the sound travels to reach this doorway
---@field at number how far along the path its far mouth sits
---@field aperture number flat gain from how open this doorway is
---@field directivity number flat gain from how squarely the sound leaves it
---@field rate number dB per 1000u this doorway's size costs past its mouth
---@field volume number the consumer's own scalar for crossing this one

---@param h doors_sound_hop
---@return doors_sound_face? source the doorway the sound radiates into
---@return doors_sound_face? listener the doorway it comes back out of
---@return number area
local function hopFaces(h)
    local intFace, extFace, area = faces(h.int)
    if intFace == nil or extFace == nil then return nil, nil, 0 end
    if h.enter then return extFace, intFace, area end
    return intFace, extFace, area
end

---@param hops doors_sound_hop[]
---@param i number
---@param int gmod_door_interior
---@param enter boolean
local function setHop(hops, i, int, enter)
    local h = hops[i]
    if h == nil then
        hops[i] = { int = int, enter = enter, area = 0, facing = 1, seg = 0, at = 0,
            aperture = 1, directivity = 1, rate = 0, volume = 1 }
        return
    end
    h.int, h.enter = int, enter
end

---@class doors_listener_chain
---@field frame number
---@field space gmod_door_interior?
---@field depth number

local listenerChain = { frame = -1, depth = 0 } ---@type doors_listener_chain
local listenerOut = {} --[[@as gmod_door_interior[] ]]
local listenerHas = {} ---@type table<gmod_door_interior, true>

-- Out of each space the sound sits in until the two share one, then into each the listener sits in.
---@param hops doors_sound_hop[]
---@param space gmod_door_interior?
---@param listenerSpace gmod_door_interior?
---@return number written into `hops`
local function chainBetween(hops, space, listenerSpace)
    if listenerChain.frame ~= FrameNumber() or listenerChain.space ~= listenerSpace then
        listenerChain.frame, listenerChain.space = FrameNumber(), listenerSpace
        for k in pairs(listenerHas) do listenerHas[k] = nil end
        local depth, up = 0, listenerSpace
        while up and depth < 16 do -- cap against a stale insideof cycle
            depth = depth + 1
            listenerOut[depth] = up
            listenerHas[up] = true
            up = containerOf(up)
        end
        listenerChain.depth = depth
    end

    local n, meet, up = 0, nil, space
    for _ = 1, 16 do
        if up == nil or listenerHas[up] then
            meet = up
            break
        end
        n = n + 1
        setHop(hops, n, up, false)
        up = containerOf(up)
    end

    local from = listenerChain.depth
    if meet then
        for i = 1, listenerChain.depth do
            if listenerOut[i] == meet then
                from = i - 1
                break
            end
        end
    end
    for i = from, 1, -1 do
        n = n + 1
        setHop(hops, n, listenerOut[i], true)
    end
    return n
end

--------------------------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------------------------

---@class doors_sound_resolution
---@field pos Vector? where the sound is heard from - the doorway itself when it comes through one
---@field dist number distance from the listener along the path the sound travels
---@field gain number everything the doorways do to it, 1 when there is no doorway in the path
---@field applied number the finished attenuation: the doorway, the distance and any glide, together
---@field hops doors_sound_hop[] the doorways in the path, `hop_count` of them live
---@field hop_count number doorways in the path, more than one only where boxes are nested
---@field int gmod_door_interior? the last boundary in the path, nil when it shares a space with you
---@field inside boolean the listener is in `int` rather than outside it
---@field emitter Vector? where the sound actually is, as opposed to where it is heard from
---@field source doors_sound_face? the doorway the sound radiates into
---@field listener doors_sound_face? the doorway it reaches the listener from
---@field normal Vector? which way that doorway faces
---@field d1 number the sound to the doorway it finally comes out of, along the path
---@field d2 number that doorway to the listener
---@field area number the tightest doorway on the path, in square units
---@field openness number how open that tightest doorway is
---@field volume number the consumer's own scalar for sound crossing the path, every boundary in it
---@field aperture number flat gain from how open the doorways are
---@field db_per_1000 number how fast the doorway sizes make the sound fall off past the last mouth
---@field extra number the extra falloff past the mouths, at this distance
---@field vol_extra number the consumer's cross-boundary volume as a falloff, 1 at the last mouth
---@field facing number -1 directly behind the last doorway, 1 head on
---@field directivity number
---@field healing number 0-1 of a captured space change still to fade
---@field space gmod_door_interior? the space the sound itself is in, nil in the open world
---@field counterpart number gain from the counterpart rule, 1 when this sound has no counterpart

---@return doors_sound_resolution
local function newResolution()
    return { dist = 0, gain = 1, applied = 1, inside = false, d1 = 0, d2 = 0, area = 0, openness = 1,
        volume = 1, aperture = 1, db_per_1000 = 0, extra = 1, vol_extra = 1, facing = 1, directivity = 1,
        healing = 0, counterpart = 1, hop_count = 0, hops = {} }
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
    res.hop_count = 0
    res.dist = pos and MainEyePos():Distance(pos) or 0
    if not pos then
        res.applied, res.healing = 1, 0
        return res
    end

    local listenerSpace = getListenerSpace()
    local space = spaceOf(handle.ent, pos)
    res.space = space

    local chain = res.hops
    local hops = chainBetween(chain, space, listenerSpace)
    local tail = 0

    if hops > 0 then
        -- Forward, aiming each doorway at whatever the sound reaches next: the one after it, or you.
        local eye, prev, travelled = MainEyePos(), pos, 0
        local source, listener, area = hopFaces(chain[1])
        for i = 1, hops do
            if source == nil or listener == nil then
                hops = 0
                break
            end
            local h = chain[i]
            h.area = area
            h.seg = prev:Distance(mouthPoint(source.ent, source.portal, prev))
            travelled = travelled + h.seg
            h.at = travelled

            local nextSource, nextListener, nextArea
            if i < hops then nextSource, nextListener, nextArea = hopFaces(chain[i + 1]) end
            local aim = nextSource and nextSource.ent:LocalToWorld(nextSource.portal.pos) or eye
            local mouth = mouthPoint(listener.ent, listener.portal, aim)
            local normal = mouthNormal(listener.ent, listener.portal)
            local out = aim - mouth
            local reach = out:Length()

            -- Standing in an opening is not standing off to one side of it, so the aim term fades
            -- out as you close on the mouth. Without that it flips hard the moment your eye passes
            -- the doorway plane, which happens a step before your body is moved through it.
            local nearField = math.min(1, reach / math.max(math.sqrt(area) * 0.5, 1))
            h.facing = reach > 1 and Lerp(nearField, 1, normal:Dot(out:GetNormalized())) or 1

            if i == hops then
                res.source, res.listener, res.normal, res.pos = source, listener, normal, mouth
            end
            prev = mouth
            source, listener, area = nextSource, nextListener, nextArea
        end
        tail = prev:Distance(eye)
    end

    if hops > 0 then
        -- Back along it, because a doorway's falloff runs over everything the sound still has to
        -- travel, which the doorways behind it do not know yet. Every per-doorway term is written to
        -- its hop as well as into the total: the debug graph is drawn from the hops, so a term that
        -- lands in only one of the two makes the graph and the audio disagree.
        local tuning = Sound.tuning
        local aperture, directivity, volume, extra, volExtra = 1, 1, 1, 1, 1
        local rate, area, open, remaining = 0, math.huge, 1, tail
        for i = hops, 1, -1 do
            local h = chain[i]
            local hopOpen = openness(h.int)

            -- math.log's base argument is a 5.2 addition GMod may not have, and is silently ignored.
            local halvings = math.max(0, math.log(SIZE_NEUTRAL / math.max(h.area, 1)) / LOG2)
            h.rate = tuning.falloff * halvings
            h.aperture = tuning.closed + (1 - tuning.closed) * hopOpen ^ tuning.curve
            h.directivity = 1 - tuning.aim * 0.5 * (1 - h.facing)
            h.volume = math.Clamp(h.int.exterior:GetCrossBoundaryVolume(), 0, 1)

            aperture, directivity = aperture * h.aperture, directivity * h.directivity
            volume, rate = volume * h.volume, rate + h.rate
            extra = extra * 10 ^ (-(h.rate * remaining / 1000) / 20)
            volExtra = volExtra * (h.volume > 0 and h.volume ^ (remaining / 1000) or 0)

            area, open = math.min(area, h.area), math.min(open, hopOpen)
            remaining = remaining + h.seg
        end

        local last = chain[hops]
        res.int, res.inside, res.facing = last.int, last.enter, last.facing
        res.area, res.openness, res.aperture = area, open, aperture
        res.db_per_1000, res.extra = rate, extra
        res.volume, res.vol_extra, res.directivity = volume, volExtra, directivity
        res.hop_count = hops
        res.gain = aperture * directivity * extra * volExtra
        res.d1, res.d2, res.dist = remaining - tail, tail, remaining
    end

    local gain = res.gain
    -- One distance gain over the whole path. Attenuating each leg separately is the obvious reading and
    -- fights Source's own curve - far enough out it makes a doorway raise the level instead of cut it.
    if handle.level then gain = gain * Sound.distance_gain(res.dist, handle.level) end
    gain = math.max(gain, GAIN_FLOOR)
    local weight, settled = counterpartGain(handle, space, listenerSpace)
    local inPair = handle.pair ~= nil and settled
    if handle.last_space ~= space or handle.last_listener_space ~= listenerSpace then
        local listenerOnly = handle.last_space == space
        local viewCut = listenerOnly and (RealTime() - listenerState.body_changed) > BODY_SETTLE
        handle.heal_span = viewCut and VIEW_TRANSITION or TRANSITION_FLOOR

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
        -- Interpolated against this frame's gain, never a dB offset captured once at the crossing:
        -- crossing moves the listener, so a stored offset multiplies whatever replaced the gain it was
        -- measured against, and runs away into a hard clip.
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
