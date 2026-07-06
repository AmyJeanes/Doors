-- Entities

---@type table<gmod_door_interior, boolean>
Doors.Interiors={}
---@api
---@param e gmod_door_interior
function Doors:AddInterior(e)
    self.Interiors[e]=true

    hook.Call("Doors-InteriorAdded", GAMEMODE, e)
end
---@api
---@param e gmod_door_interior
function Doors:RemoveInterior(e)
    self.Interiors[e]=nil

    hook.Call("Doors-InteriorRemoved", GAMEMODE, e)
end
---@api
function Doors:GetInteriors()
    return self.Interiors
end

---@type table<gmod_door_exterior, boolean>
Doors.Exteriors={}
---@api
---@param e gmod_door_exterior
function Doors:AddExterior(e)
    self.Exteriors[e]=true

    hook.Call("Doors-ExteriorAdded", GAMEMODE, e)
end
---@api
---@param e gmod_door_exterior
function Doors:RemoveExterior(e)
    self.Exteriors[e]=nil

    hook.Call("Doors-ExteriorRemoved", GAMEMODE, e)
end
---@api
function Doors:GetExteriors()
    return self.Exteriors
end
