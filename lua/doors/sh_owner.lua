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

function Doors:SetupOwner(ent,ply)
    ent:SetCreator(ply)
    if SERVER and CPPI then
        ent:CPPISetOwner(ply)
    end
    if ent.parts then
        for _,v in pairs(ent.parts) do
            Doors:SetupOwner(v,ply)
        end
    end
    if ent.DoorExterior and IsValid(ent.interior) then
        self:SetupOwner(ent.interior,ply)
    end
end