-- Doors

ENT:AddHook("Initialize", "doors", function(self)
    Doors:AddInterior(self)
end)

ENT:AddHook("OnRemove", "doors", function(self)
    Doors:RemoveInterior(self)
end)

-- The doorway on this side of the boundary, in this entity's local space. See the matching method on
-- the exterior; a consumer that fills `Portal` in server-side only should override this.
---@api
---@return doors_portal_side?
function ENT:GetDoorway()
    return self.Portal
end
