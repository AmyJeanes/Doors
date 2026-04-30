-- Hooks

if SERVER then
    local meta=assert(FindMetaTable("Entity"))
    meta.OldSetSkin=meta.OldSetSkin or meta.SetSkin
    function meta.SetSkin(ent,i,...)
        meta.OldSetSkin(ent,i,...)
        hook.Call("SkinChanged", GAMEMODE, ent, i, ...)
    end
    
    meta.OldSetBodygroup=meta.OldSetBodygroup or meta.SetBodygroup
    function meta.SetBodygroup(ent,bodygroup,value,...)
        meta.OldSetBodygroup(ent,bodygroup,value,...)
        hook.Call("BodygroupChanged", GAMEMODE, ent, bodygroup, value, ...)
    end

    hook.Add("SkinChanged", "doors", function(ent,i)
        if ent.DoorExterior or ent.DoorInterior then
            ent:CallHook("SkinChanged", i)
        end
    end)

    hook.Add("BodygroupChanged", "doors", function(ent,bodygroup,value)
        if ent.DoorExterior or ent.DoorInterior then
            ent:CallHook("BodygroupChanged", bodygroup, value)
        end
    end)
else
    hook.Add("PreDrawTranslucentRenderables", "doors-i", function()
        for k in pairs(Doors:GetInteriors()) do
            if IsValid(k) then
                k:CallHook("PreDrawTranslucentRenderables")
            end
        end
    end)
    hook.Add("PostDrawTranslucentRenderables", "doors-i", function()
        for k in pairs(Doors:GetInteriors()) do
            if IsValid(k) then
                k:CallHook("PostDrawTranslucentRenderables")
            end
        end
    end)
end