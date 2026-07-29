-- Doors

ENT:AddHook("Initialize", "doors", function(self)
    Doors:AddExterior(self)
end)

ENT:AddHook("OnRemove", "doors", function(self)
    Doors:RemoveExterior(self)
end)

---@api
---@return doors_portal_side?
function ENT:GetDoorway()
    return self.Portal or self.doorway
end

---@api
---@return number 0 shut to 1 wide open
function ENT:GetDoorOpenness()
    return 1
end

---@api
---@return number 0-1 of a sound that carries across this boundary, as a falloff past the mouth
function ENT:GetCrossBoundaryVolume()
    return 1
end
