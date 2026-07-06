-- Stops people messing with the interior

hook.Add("PhysgunPickup", "doors-freeze", function(ply,ent)
    if ent.DoorInterior then return false end
end)

hook.Add("PlayerUnfrozeObject", "doors-freeze", function(ply,ent,phys)
    if ent.DoorInterior then phys:EnableMotion(false) end
end)

hook.Add("CanProperty", "doors-freeze", function(ply,prop,ent)
    if ent.DoorInterior then return false end
end)

---@param ply Player
---@param ent Entity
hook.Add("CanDrive", "doors-freeze", function(ply,ent)
    if ent.DoorInterior then return false end
end)