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
    -- Build the stuck-trace filter from the server-side stuckfilter table (when
    -- present) plus a shared StuckFilter hook. The hook lets consumers exclude
    -- networked entities (e.g. TARDIS' interior door part) at trace time, so the
    -- server and the predicting client build identical filter membership from
    -- networked entities — required for the predicted unstick to land in the
    -- same place on both realms. Order is irrelevant (a filter is a set);
    -- CallHook returns the first non-nil result, so the owning consumer returns
    -- the whole list.
    local filter={ply}
    for _,e in ipairs(self.stuckfilter or {}) do
        filter[#filter+1]=e
    end
    local extra=self:CallHook("StuckFilter")
    if extra then
        for _,e in ipairs(extra) do
            if IsValid(e) then filter[#filter+1]=e end
        end
    end
    td.filter=filter
    return td --[[@as HullTrace]]
end

function ENT:IsStuck(ply)
    if ply:GetMoveType()==MOVETYPE_NOCLIP then return false end
    local td=self:GetStuckTrace(ply)
    local tr=util.TraceHull(td)
    return tr.Hit
end

-- Pure safe-position resolver for a player left stuck by a portal teleport.
-- Position only (no ply:SetPos / eye writes), so it runs identically on the
-- server and the predicting client: floor-snap within 10u, else the door's
-- authored Fallback safe-spot. Returns nil when neither is available, in which
-- case the caller leaves the player put and the server snapshot / NetworkOrigin
-- mask covers any correction.
--
-- This replaces the old PlayerEnter+PlayerExit "bounce": that relocated via the
-- full entry/exit path purely to reach the Fallback spot, which also did a
-- server-side ply:SetEyeAngles (discarded under prediction, and the source of
-- the spurious teleport eye-rotation) and re-fired every consumer entry/exit
-- hook a redundant second time.
function ENT:ResolveSafePos(ply, exiting)
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
        return newpos
    end

    -- No clear floor: use the door's authored fallback safe-spot.
    if IsValid(self.exterior) then
        return self.exterior:ResolveFallbackPos(ply, exiting)
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
                local safe = self:ResolveSafePos(ply, true)
                if safe then ply:SetPos(safe) end
            end
            if IsValid(portal) and IsValid(portal.interior) and portal.interior.DoorInterior then
                portal.interior:CheckPlayer(ply)
            end
        elseif not self.occupants[ply] and inbox then
            --print("in",self,ply,ply:GetPos())
            self.exterior:PlayerEnter(ply,true)
            if IsValid(portal) and portal==self.portals.exterior and self:IsStuck(ply) then
                --print("stuck in",self,ply,portal)
                local safe = self:ResolveSafePos(ply, false)
                if safe then ply:SetPos(safe) end
            end
        end
    end
    
    ENT:AddHook("Think", "handleplayers", function(self)
        if not self._init then return end
        for _,v in pairs(player.GetAll()) do
            self:CheckPlayer(v)
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
end

-- ShouldTeleportPortal must register on both realms so the predicted
-- player teleport in world-portals' SetupMove can also veto on the
-- client (otherwise we predict the teleport, server vetoes it via
-- CanPlayerExit, and the player rubberbands back via snapshot). The
-- handler itself is realm-safe: CallHook("CanPlayerExit", ent) returns
-- nil on the client unless a consumer also registered a shared handler,
-- which is the right opt-in shape.
ENT:AddHook("ShouldTeleportPortal", "handleplayers", function(self,portal,ent)
    if IsValid(ent) and ent:IsPlayer() and portal==self.portals.interior and self.exterior:CallHook("CanPlayerExit",ent)==false then
        return false
    end
end)

if CLIENT then

    -- Predicted exit (world-portals SetupMove path). The wp-teleport hook
    -- routes through the portal's parent — for the main interior portal
    -- that's `self`, so PostTeleportPortal fires here. Customportals also
    -- route to `self` but stay inside the interior, so we gate on
    -- portal == self.portals.interior.
    ENT:AddHook("PostTeleportPortal", "predict", function(self, portal, ent)
        if ent ~= LocalPlayer() then return end
        if not (self.portals and portal == self.portals.interior) then return end
        ent.door = nil
        ent.doori = nil
        if IsValid(self.exterior) and self.exterior.occupants then
            self.exterior.occupants[ent] = nil
        end
        -- Predict the unstick the server runs in CheckPlayer, so the landing
        -- matches and world-portals' mv re-sync keeps it (no rubberband).
        -- Position only; ResolveSafePos is pure so this is deterministic and
        -- idempotent. Degrades to server-authoritative if not stuck client-side.
        if self:IsStuck(ent) then
            local safe = self:ResolveSafePos(ent, true)
            if safe then ent:SetPos(safe) end
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