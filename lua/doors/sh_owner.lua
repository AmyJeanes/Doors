-- Owner

if CLIENT then
    local meta=assert(FindMetaTable("Entity"))
    if not meta.SetCreator and not meta.GetCreator then
        ---@param creator Player
        function meta:SetCreator(creator)
            self._creator=creator
        end

        function meta:GetCreator()
            -- networked so it resolves once the creator's player reaches this client and survives reconnects; _creator is the pre-net fallback
            return self:GetNW2Entity("_doorscreator", self._creator or NULL)
        end
    end
end

---@api
---@param ent Entity
---@param ply Player
function Doors:SetupOwner(ent,ply)
    ent:SetCreator(ply)
    if SERVER then
        if IsValid(ply) then
            ent:SetNW2Entity("_doorscreator",ply)
            if ply:IsPlayer() and not ply:IsBot() then
                ent._creatorsteamid=ply:SteamID()
            end
        end
        if CPPI then
            ent:CPPISetOwner(ply)
        end
    end
    if ent.CallHook then
        ent:CallHook("SetupOwner",ply)
    end
    if ent.DoorExterior and IsValid(ent.interior) then
        self:SetupOwner(ent.interior,ply)
    end
end

if SERVER then
    hook.Add("PlayerInitialSpawn","Doors-RestoreCreator",function(ply)
        local sid=ply:SteamID()
        for ent in pairs(Doors.Exteriors) do
            if IsValid(ent) and ent._creatorsteamid==sid and not IsValid(ent:GetCreator()) then
                Doors:SetupOwner(ent,ply)
            end
        end
    end)
end
