-- Owner

if CLIENT then
    local meta=assert(FindMetaTable("Entity"))
    if not meta.SetCreator and not meta.GetCreator then
        ---@param creator Player
        function meta:SetCreator(creator)
            self._creator=creator
        end

        function meta:GetCreator()
            return self._creator
        end
    end
end

---@api
---@param ent Entity
---@param ply Player
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