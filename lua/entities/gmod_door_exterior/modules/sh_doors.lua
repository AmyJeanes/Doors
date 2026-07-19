-- Doors

ENT:AddHook("Initialize", "doors", function(self)
    Doors:AddExterior(self)
end)

ENT:AddHook("OnRemove", "doors", function(self)
    Doors:RemoveExterior(self)
end)

-- The doorway on this side of the boundary, in this entity's local space. Cross-boundary audio needs
-- it in both realms, so a consumer that only fills `Portal` in on the server should override this.
---@api
---@return doors_portal_side?
function ENT:GetDoorway()
    return self.Portal
end

-- How open this doorway is, 0 shut to 1 wide open. A plain doorway is a hole in a wall and is always
-- open; a consumer whose door animates overrides this with its own position, and anything that reads
-- the boundary - cross-boundary audio in particular - follows it continuously rather than as a switch.
---@api
---@return number
function ENT:GetDoorOpenness()
    return 1
end
