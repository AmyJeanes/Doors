-- Doors

ENT:AddHook("Initialize", "doors", function(self)
    Doors:AddInterior(self)
end)

ENT:AddHook("OnRemove", "doors", function(self)
    Doors:RemoveInterior(self)
end)

---@api
---@return doors_portal_side?
function ENT:GetDoorway()
    return self.Portal or self.doorway
end
