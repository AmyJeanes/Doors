-- Handles players inside the interior

---@api
---@param pos Vector
---@return boolean
function ENT:PositionInside(pos)
    if self.ExitBox and (pos:WithinAABox(self:LocalToWorld(self.ExitBox.Min),self:LocalToWorld(self.ExitBox.Max))) then
        return true
    elseif self.ExitDistance and pos:Distance(self:GetPos()) < self.ExitDistance then
        return true
    end
    return false
end

---@param ply Player
function ENT:GetStuckTrace(ply)
    local pos=ply:GetPos()
    local td={}
    td.start=pos
    td.endpos=pos
    td.mins=ply:OBBMins()
    td.maxs=ply:OBBMaxs()
    -- Use the player's movement mask, not the trace default (MASK_SOLID), which can read a
    -- player wedged in a solid (a TARDIS shell) as ~clear so the unstick falsely "succeeds".
    td.mask=MASK_PLAYERSOLID
    -- The StuckFilter hook lets a consumer add networked entities for this trace to
    -- ignore. They must be networked so the predicting client and server build the
    -- same filter - the predicted unstick has to resolve to the same spot on both.
    local filter={ply}
    local extra=self:CallHook("StuckFilter")
    if extra then
        for _,e in ipairs(extra) do
            if IsValid(e) then filter[#filter+1]=e end
        end
    end
    td.filter=filter
    return td --[[@as HullTrace]]
end

---@api
---@param ply Player
function ENT:IsStuck(ply)
    if ply:GetMoveType()==MOVETYPE_NOCLIP then return false end
    local td=self:GetStuckTrace(ply)
    local tr=util.TraceHull(td)
    return tr.Hit
end

-- True when our own exterior is parked inside our interior (self-nested, e.g. a TARDIS
-- landed inside itself). Crossing the interior door then keeps the player inside us
-- instead of putting them out, so the enter/exit and predicted paths special-case it.
---@api
function ENT:ExteriorIsNested()
    return IsValid(self.exterior) and self:PositionInside(self.exterior:GetPos())
end

-- Position only - no eye writes or hooks. Runs in the predicted unstick path on
-- both realms (and every client resim), so it must stay pure and idempotent.
---@api
---@param ply Player
---@param exiting boolean?
function ENT:ResolveSafePos(ply, exiting)
    ---@param pos Vector
    local function clear(pos)
        local t = self:GetStuckTrace(ply)
        t.start = pos
        t.endpos = pos
        return not util.TraceHull(t).Hit
    end
    -- Settle straight down onto the floor under a clear point (flattened hull so a low
    -- ceiling doesn't block the drop).
    ---@param top Vector
    ---@param drop number
    local function floorSnap(top, drop)
        local t = self:GetStuckTrace(ply)
        t.maxs.z = t.mins.z
        t.start = top
        t.endpos = top - Vector(0, 0, drop)
        return util.TraceHull(t).HitPos
    end

    local base = ply:GetPos()

    -- 1. Step up onto a ledge. The common portal-exit embed is the feet caught a couple
    -- of units in a door sill; rising onto it barely moves the player (it settles back
    -- near in place), so try it before the forward shove, which overshoots far enough to
    -- read as a teleport. Lift until the hull clears, then settle back down onto the ledge.
    for up = 2, 20, 2 do
        local top = base + Vector(0, 0, up)
        if clear(top) then
            local floor = floorSnap(top, up + 12)
            if floor and clear(floor) then return floor end
            return top
        end
    end

    -- 2. Push out along the door we emerged from - a real horizontal embed (an exterior
    -- shell parked inside an interior) that lifting can't clear. Sweep to a clear spot
    -- away from the crossing plane, then settle onto the floor there.
    local door = exiting and self.portals.exterior or self.portals.interior
    if IsValid(door) then
        local fwd = door:GetForward()
        fwd.z = 0
        if fwd:LengthSqr() > 0.001 then
            fwd:Normalize()
            for dist = 8, 128, 8 do
                local test = base + fwd * dist
                if clear(test) then
                    local snapped = floorSnap(test + Vector(0, 0, 12), 96)
                    if snapped and clear(snapped) then return snapped end
                    return test
                end
            end
        end
    end

    -- 3. No clear spot: use the door's authored fallback safe-spot.
    if IsValid(self.exterior) then
        return self.exterior:ResolveFallbackPos(ply, exiting)
    end
end

if SERVER then
    ---@param ply Player
    ---@param portal linked_portal_door?
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
        elseif self.occupants[ply] and inbox and IsValid(portal) and portal==self.portals.interior
            and self:ExteriorIsNested() and self:IsStuck(ply) then
            -- Walked out our interior door but our exterior is parked inside us: stay an
            -- occupant and push out of the shell into the room (snapping to the door would
            -- re-cross and bounce).
            local safe = self:ResolveSafePos(ply, true)
            if safe then ply:SetPos(safe) end
        end
    end
    
    ENT:AddHook("Think", "handleplayers", function(self)
        if not self._init then return end
        for _,v in pairs(player.GetAll()) do
            self:CheckPlayer(v)
        end
    end)

    local UNSTICK_WINDOW = 0.25 -- seconds after a crossing to watch for a settle into a shell

    -- A player can settle a fraction into an exterior shell parked inside us (self-nested, or a
    -- TARDIS in another TARDIS) a tick or two after crossing - too late for the crossing-time
    -- unstick. For a short window after a teleport (armed below), re-resolve an occupant that
    -- lands stuck. Bounded to that window so we never yank a player stuck for an unrelated reason.
    ENT:AddHook("Think", "unstick-occupant", function(self)
        if not self._init or not self.occupants then return end
        for ply in pairs(self.occupants) do
            if IsValid(ply) and ply:IsPlayer() and (ply.DoorsUnstickUntil or 0) > CurTime() and self:IsStuck(ply) then
                local hit = util.TraceHull(self:GetStuckTrace(ply)).Entity
                -- resolve via the shell they're stuck in, so its OWN exit door escapes it (ours may point wrong)
                local resolver = self
                if IsValid(hit) then
                    local shellInt = hit.interior
                    if IsValid(shellInt) and shellInt.ResolveSafePos then resolver = shellInt end
                end
                if IsValid(resolver) then
                    local safe = resolver:ResolveSafePos(ply, true)
                    if safe then ply:SetPos(safe) end
                end
            end
        end
    end)

    ---@param portal linked_portal_door
    ---@param ent Entity
    hook.Add("wp-teleport","doors-handleplayers",function(portal,ent)
        if ent:IsPlayer() then
            ent.DoorsUnstickUntil = CurTime() + UNSTICK_WINDOW -- arm the settle-into-shell recheck
            for k in pairs(Doors:GetInteriors()) do
                k:CheckPlayer(ent,portal)
            end
        end
    end)
else
    ENT:AddHook("Initialize", "handleplayers", function(self)
        self.occupants=self.exterior.occupants -- Hooray for referenced tables
    end)

    -- Local player is inside this interior: occupying it directly (doori), or standing in
    -- a box nested inside us at any depth (a TARDIS in a TARDIS in us) - walk out each
    -- containing box via insideof. One source of truth for every render/think gate.

    ---@api
    ---@return boolean
    function ENT:LocalPlayerInside()
        local ply = LocalPlayer()
        if ply.doori == self then return true end
        if not self.contains then return false end
        local box = ply.door
        for _ = 1, 16 do -- cap against a stale insideof cycle
            if not IsValid(box) then return false end
            if self.contains[box] then return true end
            local int = box.insideof
            box = IsValid(int) and int.exterior or nil
        end
        return false
    end

    ENT:AddHook("ShouldDraw", "handleplayers", function(self)
        if not self:LocalPlayerInside() and not self:RenderingThroughCordonCamera() and not wp.drawing then
            return false
        end
    end)

    -- The emerged-half ghost sits at our interior portal, which parks in the skybox
    -- hidden from the open world. Mirror our ShouldDraw so the ghost hides whenever
    -- the interior does, instead of floating in empty sky.
    ENT:AddHook("ShouldDrawGhost", "handleplayers", function(self, ent, ghost, portal, exit)
        if not (self.portals and exit == self.portals.interior) then return end
        if self:CallHook("ShouldDraw") == false then return false end
    end)

    ENT:AddHook("ShouldThink", "handleplayers", function(self)
        if not self:LocalPlayerInside() then
            return false
        end
    end)
end

-- Shared so world-portals' predicted SetupMove teleport runs this veto on the client
-- too. The veto only predicts if the consumer's CanPlayerExit is also shared; a
-- server-only CanPlayerExit still vetoes on the server, but the client rubberbands.
ENT:AddHook("ShouldTeleportPortal", "handleplayers", function(self,portal,ent)
    if IsValid(ent) and ent:IsPlayer() and portal==self.portals.interior and self.exterior:CallHook("CanPlayerExit",ent)==false then
        return false
    end
end)

if CLIENT then

    -- Predicted exit (SetupMove): clear the player's door fields immediately so the
    -- interior stops rendering this frame - the predicted crossing can land before the
    -- server catches up. The Doors-EnterExit broadcast re-sets the same fields soon after.
    ENT:AddHook("PostTeleportPortal", "predict", function(self, portal, ent)
        if ent ~= LocalPlayer() then return end
        -- Gate on the main interior portal: customportals route here too but keep the player inside.
        if not (self.portals and portal == self.portals.interior) then return end
        -- Self-nested (our exterior parked inside us): crossing the interior door keeps
        -- the player inside, so don't predict an exit - that would blank the interior this
        -- frame and desync from the server, which never exits them. Just unstick to the
        -- interior fallback, matching the server's landing.
        if self:ExteriorIsNested() then
            if self:IsStuck(ent) then
                local safe = self:ResolveSafePos(ent, true)
                if safe then ent:SetPos(safe) end
            end
            return
        end
        ent.door = nil
        ent.doori = nil
        if IsValid(self.exterior) and self.exterior.occupants then
            self.exterior.occupants[ent] = nil
        end
        -- Predict the exit unstick so the landing matches the server's. ResolveSafePos
        -- is pure, so re-running it each resim is safe; if not stuck client-side it just
        -- defers to the server.
        if self:IsStuck(ent) then
            local safe = self:ResolveSafePos(ent, true)
            if safe then ent:SetPos(safe) end
        end
        -- If our exterior is parked inside another interior, we just emerged into that
        -- one (a TARDIS inside a different TARDIS). Predict entering it so the client
        -- doesn't blank to sky: the server enters us there too, but its enter broadcast
        -- loses the one-frame race to the doori clear above.
        for k in pairs(Doors:GetInteriors()) do
            if k ~= self and IsValid(k) and IsValid(k.exterior) and k:PositionInside(ent:GetPos()) then
                ent.door = k.exterior
                ent.doori = k
                if k.exterior.occupants then k.exterior.occupants[ent] = true end
                break
            end
        end
    end)

    ---@param int gmod_door_interior
    local function renderingOutOwnDoor(int)
        local portals = int.portals
        if not (wp.drawing and portals and wp.drawingent == portals.interior) then return false end
        return not (IsValid(int.exterior) and IsValid(int.exterior.insideof))
    end

    hook.Add("PrePlayerDraw", "doors-handleplayers", function(ply)
        local int=ply.doori
        if not IsValid(int) then return end
        local localply=LocalPlayer()
        local localplyinside=int:LocalPlayerInside()
        local drawingportal=wp.drawing and wp.drawingent==int.portals.exterior
        local shoulddraw=int:CallHook("ShouldDrawPlayer", ply, localply)
        if renderingOutOwnDoor(int) or ((not localplyinside or shoulddraw==false) and not drawingportal) then
            return true
        end
        int:CallHook("PreDrawPlayer", ply)
    end)

    hook.Add("PostPlayerDraw", "doors-handleplayers", function(ply)
        local int=ply.doori
        if not IsValid(int) then return end
        int:CallHook("PostDrawPlayer", ply)
    end)

    hook.Add("DrawPhysgunBeam", "doors-handleplayers", function(ply)
        local int=ply.doori
        if not IsValid(int) then return end
        local localply=LocalPlayer()
        local localplyinside=int:LocalPlayerInside()
        local drawingportal=wp.drawing and wp.drawingent==int.portals.exterior
        local shoulddraw=int:CallHook("ShouldDrawPlayer", ply, localply)
        if renderingOutOwnDoor(int) or ((not localplyinside or shoulddraw==false) and not drawingportal) then
            return false
        end
    end)
end
