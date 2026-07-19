-- Doors

ENT:AddHook("Initialize", "doors", function(self)
    Doors:AddInterior(self)
end)

ENT:AddHook("OnRemove", "doors", function(self)
    Doors:RemoveInterior(self)
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
