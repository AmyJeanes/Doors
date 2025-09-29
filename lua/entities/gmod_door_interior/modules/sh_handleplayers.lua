-- Handles players inside the interior

function ENT:PositionInside(pos)
    if self.ExitBox and (pos:WithinAABox(self:LocalToWorld(self.ExitBox.Min),self:LocalToWorld(self.ExitBox.Max))) then
        return true
    elseif self.ExitDistance and pos:Distance(self:GetPos()) < self.ExitDistance then
        return true
    end
    return false
end

function ENT:GetStuckTrace(ply)
    local pos=ply:GetPos()
    local td={}
    td.start=pos
    td.endpos=pos
    td.mins=ply:OBBMins()
    td.maxs=ply:OBBMaxs()
    td.filter={ply,unpack(self.stuckfilter)}
    return td
end

function ENT:IsStuck(ply)
    if ply:GetMoveType()==MOVETYPE_NOCLIP then return false end
    local pos=ply:GetPos()
    local td=self:GetStuckTrace(ply)
    local tr=util.TraceHull(td)
    return tr.Hit
end

function ENT:IsThisSafe(ply, dist) -- Checking in advance to teleporting as actually using the player, this is because teleporting the player then teleporting again to the fallback location causes flashing
    local pos=ply:GetPos() + dist
    local td={}
    td.start=pos
    td.endpos=pos
    td.mins=ply:OBBMins()
    td.maxs=ply:OBBMaxs()
    td.filter={ply,unpack(self.stuckfilter)}
    local tr=util.TraceHull(td)
    return !tr.Hit
end

function ENT:UnStick(ply, portal, exiting)
    local pos=ply:GetPos()
    local td=self:GetStuckTrace(ply)
    td.maxs.z=td.mins.z -- Ignore head height for the snapping to floor bit to avoid conflicting with low ceilings
    td.start = td.start + Vector(0,0,10)
    local tr = util.TraceHull(td)
    local dist = tr.HitPos - pos
    print(dist)
    if tr.HitPos and self:IsThisSafe(ply, dist) then
        ply:SetPos(tr.HitPos)
    else
        if exiting then
            self.exterior:PlayerEnter(ply)
            self.exterior:PlayerExit(ply)
        else
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
                self:UnStick(ply,portal,true)
            end
            if IsValid(portal) and IsValid(portal.interior) and portal.interior.DoorInterior then
                portal.interior:CheckPlayer(ply)
            end
        elseif not self.occupants[ply] and inbox then
            --print("in",self,ply,ply:GetPos())
            self.exterior:PlayerEnter(ply,true)
            if IsValid(portal) and portal==self.portals.exterior and self:IsStuck(ply) then
                --print("stuck in",self,ply,portal)
                self:UnStick(ply,portal,false)
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