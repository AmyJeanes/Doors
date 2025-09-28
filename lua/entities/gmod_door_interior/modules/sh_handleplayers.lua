-- Handles players inside the interior

function ENT:PositionInside(pos)
    if self.ExitBox and (pos:WithinAABox(self:LocalToWorld(self.ExitBox.Min),self:LocalToWorld(self.ExitBox.Max))) then
        return true
    elseif self.ExitDistance and pos:Distance(self:GetPos()) < self.ExitDistance then
        return true
    end
    return false
end

function ENT:IsStuck(ply)
    if ply:GetMoveType()==MOVETYPE_NOCLIP then return false end
    local pos=ply:GetPos()
    local td={}
    td.start=pos
    td.endpos=pos
    td.mins=ply:OBBMins()
    td.maxs=ply:OBBMaxs()
    td.filter={ply,unpack(self.stuckfilter)}
    local tr=util.TraceHull(td)
    return tr.Hit
end

function ENT:IsThisSafe(plybox) -- Uses a fake player hitbox to check subsequent spots as actually teleporting the player causes camera issues
    local pos=plybox.pos
    local td={}
    td.start=pos
    td.endpos=pos
    td.mins=plybox.mins
    td.maxs=plybox.maxs
    td.filter={plybox,unpack(self.stuckfilter)}
    local tr=util.TraceHull(plybox)
    return tr.Hit
end

function ENT:UnStick(ply, portal)
    -- print("Unsticking!")
    local pos=ply:GetPos()
    local plybox={}
    plybox.start=pos
    plybox.endpos=pos
    plybox.mins=ply:OBBMins()
    plybox.maxs=ply:OBBMaxs()
    plybox.filter={ply,unpack(self.stuckfilter)}
    local distance = Vector(0, 0, 0)
    while self:IsThisSafe(plybox) and (distance.z < 10) do -- Distance limit is 10 units, if greater it'll use the fallback instead
        plybox.mins = (plybox.mins + Vector(0, 0, 1)) --2 instead of just 1 as it has a less chance of failing
        plybox.maxs = (plybox.maxs + Vector(0, 0, 1))
        distance = (distance + Vector(0, 0, 1))
    end
    -- print(distance)
    if (distance.z < 10) then
        ply:SetPos(ply:GetPos()+distance)
    end
    if (distance.z >= 10) and self:IsStuck(ply) then
        -- print("Failed to unstick, using fallback")
        if IsValid(portal) and portal==self.portals.interior and self:IsStuck(ply) then
            self.exterior:PlayerEnter(ply)
            self.exterior:PlayerExit(ply)
        elseif IsValid(portal) and portal==self.portals.exterior and self:IsStuck(ply) then
            self.exterior:PlayerExit(ply)
            self.exterior:PlayerEnter(ply)
        end
    end
end

if SERVER then
    function ENT:CheckPlayer(ply,portal)
        local inbox = self:PositionInside(ply:GetPos())
        if self.occupants[ply] and not inbox then
            --print("out",self,ply,ply.door,ply.doori)
            self.exterior:PlayerExit(ply,true,IsValid(portal))
            if IsValid(portal) and portal==self.portals.interior and self:IsStuck(ply) then
                --print("stuck out",self,ply,portal)
                self:UnStick(ply, portal)
            end
            if IsValid(portal) and IsValid(portal.interior) and portal.interior.DoorInterior then
                portal.interior:CheckPlayer(ply)
            end
        elseif not self.occupants[ply] and inbox then
            --print("in",self,ply,ply:GetPos())
            self.exterior:PlayerEnter(ply,true)
            if IsValid(portal) and portal==self.portals.exterior and self:IsStuck(ply) then
                --print("stuck in",self,ply,portal)
                self:UnStick(ply, portal)
            end
        end
    end
    
    ENT:AddHook("Think", "handleplayers", function(self)
        if not self._init then return end
        for k,v in pairs(player.GetAll()) do
            self:CheckPlayer(v)
        end
    end)

    ENT:AddHook("ShouldTeleportPortal", "handleplayers", function(self,portal,ent)
        if IsValid(ent) and ent:IsPlayer() and portal==self.portals.interior and self.exterior:CallHook("CanPlayerExit",ent)==false then
            return false
        end
    end)
    
    hook.Add("wp-teleport","doors-handleplayers",function(portal,ent)
        if ent:IsPlayer() then
            for k,v in pairs(Doors:GetInteriors()) do
                k:CheckPlayer(ent,portal)
            end
        end
    end)
else
    ENT:AddHook("ShouldDraw", "handleplayers", function(self)
        if (LocalPlayer().doori~=self) and not wp.drawing and not self.contains[LocalPlayer().door] then
            return false
        end
    end)
    ENT:AddHook("ShouldThink", "handleplayers", function(self)
        if LocalPlayer().doori~=self then
            return false
        end
    end)
end