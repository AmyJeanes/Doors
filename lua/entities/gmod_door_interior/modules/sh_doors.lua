-- Doors

ENT:AddHook("Initialize", "doors", function(self)
    Doors:AddInterior(self)
end)

ENT:AddHook("OnRemove", "doors", function(self)
    Doors:RemoveInterior(self)
end)

-- Overridable by a consumer. `Portal` is server-side only, being where the portals are built from, so
-- the client answers from the copy Doors networks at player init - an override is only needed where the
-- doorway *changes* and a value sent once would go stale.

---@api
---@return doors_portal_side?
function ENT:GetDoorway()
    return self.Portal or self.doorway
end
