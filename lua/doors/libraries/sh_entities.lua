-- Entities

Doors.Interiors={}
function Doors:AddInterior(e)
    self.Interiors[e]=true

    hook.Call("Doors-InteriorAdded", GAMEMODE, e)
end
function Doors:RemoveInterior(e)
    self.Interiors[e]=nil

    hook.Call("Doors-InteriorRemoved", GAMEMODE, e)
end
function Doors:GetInteriors()
    return self.Interiors
end

Doors.Exteriors={}
function Doors:AddExterior(e)
    self.Exteriors[e]=true

    hook.Call("Doors-ExteriorAdded", GAMEMODE, e)
end
function Doors:RemoveExterior(e)
    self.Exteriors[e]=nil

    hook.Call("Doors-ExteriorRemoved", GAMEMODE, e)
end
function Doors:GetExteriors()
    return self.Exteriors
end
