-- Stops people messing with the interior

---@param ply Player
---@param ent Entity
hook.Add("PhysgunPickup", "doors-freeze", function(ply,ent)
    if ent.DoorInterior then return false end
end)

---@param ply Player
---@param ent Entity
---@param phys PhysObj
hook.Add("PlayerUnfrozeObject", "doors-freeze", function(ply,ent,phys)
    if ent.DoorInterior then phys:EnableMotion(false) end
end)

---@param ply Player
---@param prop string
---@param ent Entity
hook.Add("CanProperty", "doors-freeze", function(ply,prop,ent)
    if ent.DoorInterior then return false end
end)

---@param ply Player
---@param ent Entity
hook.Add("CanDrive", "doors-freeze", function(ply,ent)
    if ent.DoorInterior then return false end
end)