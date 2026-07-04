-- Owner

if CLIENT then
    local meta=assert(FindMetaTable("Entity"))
    if not meta.SetCreator and not meta.GetCreator then
        function meta:SetCreator(creator)
            self._creator=creator
        end

        function meta:GetCreator(creator)
            return self._creator
        end
    end
end

---@api
function Doors:SetupOwner(ent,ply)
    ent:SetCreator(ply)
    if SERVER and CPPI then
        ent:CPPISetOwner(ply)
    end
    if ent.CallHook then
        ent:CallHook("SetupOwner",ply)
    end
    if ent.DoorExterior and IsValid(ent.interior) then
        self:SetupOwner(ent.interior,ply)
    end
end