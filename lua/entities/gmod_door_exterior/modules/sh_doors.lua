-- Doors

ENT:AddHook("Initialize", "doors", function(self)
    Doors:AddExterior(self)
end)

ENT:AddHook("OnRemove", "doors", function(self)
    Doors:RemoveExterior(self)
end)

-- Overridable by a consumer. `Portal` is server-side only, being where the portals are built from, so
-- the client answers from the copy Doors networks at player init - an override is only needed where the
-- doorway *changes* and a value sent once would go stale.

---@api
---@return doors_portal_side?
function ENT:GetDoorway()
    return self.Portal or self.doorway
end

-- A plain doorway is a hole in a wall, so always open. A consumer whose door animates overrides this,
-- and readers follow it continuously rather than as a switch.

---@api
---@return number 0 shut to 1 wide open
function ENT:GetDoorOpenness()
    return 1
end

-- Separate from openness because it is a preference, not a fact about the world: two players may hear
-- the same door differently through this and only this.

---@api
---@return number 0-1 of a sound that carries across this boundary, as a falloff past the mouth
function ENT:GetCrossBoundaryVolume()
    return 1
end
