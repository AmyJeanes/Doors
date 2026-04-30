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
    return td --[[@as HullTrace]]
end

function ENT:IsStuck(ply)
    if ply:GetMoveType()==MOVETYPE_NOCLIP then return false end
    local td=self:GetStuckTrace(ply)
    local tr=util.TraceHull(td)
    return tr.Hit
end

function ENT:UnStick(ply, portal, exiting)
    -- Find closest floor position within 10 units
    local td=self:GetStuckTrace(ply)
    local oldmaxsz=td.maxs.z
    td.maxs.z=td.mins.z -- Ignore head height for floor snap due to low ceilings
    td.start = td.start + Vector(0,0,10)
    local tr = util.TraceHull(td)
    local newpos = tr.HitPos

    -- Reset trace parameters to check if new position is valid
    td.maxs.z=oldmaxsz
    td.start=newpos
    td.endpos=newpos

    if newpos and not util.TraceHull(td).Hit then
        -- New floor position is valid
        ply:SetPos(newpos)
    else
        -- New floor position is invalid, use fallback
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
        for _,v in pairs(player.GetAll()) do
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
            for k in pairs(Doors:GetInteriors()) do
                k:CheckPlayer(ent,portal)
            end
        end
    end)
else
    ENT:AddHook("Initialize", "handleplayers", function(self)
        self.occupants=self.exterior.occupants -- Hooray for referenced tables
    end)

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

    hook.Add("PrePlayerDraw", "doors-handleplayers", function(ply)
        local int=ply.doori
        if not IsValid(int) then return end
        local localply=LocalPlayer()
        local localplyinside=localply.doori==int
        local drawingportal=wp.drawing and wp.drawingent==int.portals.exterior
        local shoulddraw=int:CallHook("ShouldDrawPlayer", ply, localply)
        if (not localplyinside or shoulddraw==false) and not drawingportal then
            return true
        end
    end)

    hook.Add("DrawPhysgunBeam", "doors-handleplayers", function(ply)
        local int=ply.doori
        if not IsValid(int) then return end
        local localply=LocalPlayer()
        local localplyinside=localply.doori==int
        local drawingportal=wp.drawing and wp.drawingent==int.portals.exterior
        local shoulddraw=int:CallHook("ShouldDrawPlayer", ply, localply)
        if (not localplyinside or shoulddraw==false) and not drawingportal then
            return false
        end
    end)
end