-- Doors

ENT:AddHook("Initialize", "doors", function(self)
    Doors:AddExterior(self)
end)

ENT:AddHook("OnRemove", "doors", function(self)
    Doors:RemoveExterior(self)
end)

-- The doorway on this side of the boundary, in this entity's local space.
--
-- `Portal` is set by the consumer and only server-side, since that is where it is needed to build the
-- portals - so on the client this answers from the copy Doors networks at player init instead. A
-- consumer only needs to override this if its doorway *changes*, where a value sent once goes stale.
---@api
---@return doors_portal_side?
function ENT:GetDoorway()
    return self.Portal or self.doorway
end

-- How open this doorway is, 0 shut to 1 wide open. A plain doorway is a hole in a wall and is always
-- open; a consumer whose door animates overrides this with its own position, and anything that reads
-- the boundary - cross-boundary audio in particular - follows it continuously rather than as a switch.
---@api
---@return number
function ENT:GetDoorOpenness()
    return 1
end

-- How far sound carries across this boundary, 0 to 1 - a falloff, not a flat level. It is the fraction of
-- the geometry-only level still heard a reference 1000u past the mouth; an open mouth is always at full
-- strength (a hole in the wall, so only the closed coefficient may reduce a sound there) and it fades from
-- there. 1 passes it through at whatever the geometry says, 0 switches cross-boundary audio off entirely.
-- Separate from openness because it is a preference, not a fact about the world - two players may hear the
-- same door differently through this and only this - so a consumer offering it as a setting scales it here.
---@api
---@return number
function ENT:GetCrossBoundaryVolume()
    return 1
end
