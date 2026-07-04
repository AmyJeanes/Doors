-- Entities

Doors.Interiors={}
---@api
function Doors:AddInterior(e)
    self.Interiors[e]=true

    hook.Call("Doors-InteriorAdded", GAMEMODE, e)
end
---@api
function Doors:RemoveInterior(e)
    self.Interiors[e]=nil

    hook.Call("Doors-InteriorRemoved", GAMEMODE, e)
end
---@api
function Doors:GetInteriors()
    return self.Interiors
end

Doors.Exteriors={}
---@api
function Doors:AddExterior(e)
    self.Exteriors[e]=true

    hook.Call("Doors-ExteriorAdded", GAMEMODE, e)
end
---@api
function Doors:RemoveExterior(e)
    self.Exteriors[e]=nil

    hook.Call("Doors-ExteriorRemoved", GAMEMODE, e)
end
---@api
function Doors:GetExteriors()
    return self.Exteriors
end
