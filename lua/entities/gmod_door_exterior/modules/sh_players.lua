-- Handles players

---@class Player
---@field door gmod_door_exterior?
---@field doori gmod_door_interior?

local DOORWAY_CLEARANCE = 48

-- Fan a batch of placements out to clear ground so occupants placed at once (forced
-- exit/enter, or everyone as the door is removed) don't stack on the single fallback point.
---@param ply Player
---@param origin Vector
---@param avoid Vector? doorway to steer clear of
---@return Vector
function ENT:ResolveClearPos(ply, origin, avoid)
    local int = self.interior
    ---@param pos Vector
    ---@param drop boolean?
    ---@return TraceResult
    local function hull(pos, drop)
        ---@type table
        local td
        if IsValid(int) then
            td = int:GetStuckTrace(ply)
        else -- interior gone (removed with us): a plain player hull is enough
            td = { mins = ply:OBBMins(), maxs = ply:OBBMaxs(),
                mask = MASK_PLAYERSOLID, collisiongroup = COLLISION_GROUP_PLAYER, filter = { ply } }
        end
        if drop then td.maxs = Vector(td.maxs.x, td.maxs.y, td.mins.z) end
        td.start = pos
        td.endpos = drop and pos - Vector(0, 0, 96) or pos
        return util.TraceHull(td --[[@as HullTrace]])
    end

    if not hull(origin).Hit then return origin end
    for radius = 24, 216, 24 do
        for i = 0, 11 do
            local a = (i / 12) * math.pi * 2
            local ring = origin + Vector(math.cos(a), math.sin(a), 0) * radius
            if not (avoid and ring:Distance2D(avoid) < DOORWAY_CLEARANCE) then
                local snap = hull(ring + Vector(0, 0, 12), true)
                -- don't settle onto another player's head (vertical stacking)
                if not (IsValid(snap.Entity) and snap.Entity:IsPlayer()) and not hull(snap.HitPos).Hit then
                    return snap.HitPos
                end
            end
        end
    end
    return origin
end

---@api
---@param ply Player
---@param exiting boolean?
function ENT:ResolveFallbackPos(ply, exiting)
    local target, fb
    if exiting then
        target, fb = self, self.Fallback
    elseif IsValid(self.interior) then
        target, fb = self.interior, self.interior.Fallback
    end
    if not target then return end
    if not fb then return end
    -- doorway to steer the fan-out clear of: interior portal on entry, exterior on exit
    local avoid
    if IsValid(self.interior) and self.interior.portals then
        local p = exiting and self.interior.portals.exterior or self.interior.portals.interior
        if IsValid(p) then avoid = p:GetPos() end
    end
    local newpos = target:LocalToWorld(fb.pos)
    local height = ply:OBBMaxs().z
    local up = Vector(0, 0, height)
    up:Rotate(Angle(0, 0, target:GetAngles().r))
    -- roll compensation: keep the eyeline level when the frame's rolled (no-op unrolled)
    return self:ResolveClearPos(ply, newpos + Vector(0, 0, (up.z - height) / 2), avoid)
end

if SERVER then
    util.AddNetworkString("Doors-EnterExit")

    ---@api
    ---@param ply Player
    ---@param notp boolean?
    function ENT:PlayerEnter(ply,notp)
        if ply.doors_cooldowncur and ply.doors_cooldowncur>CurTime() then return end
        if self.occupants[ply] then
            return
        end
        local allowed,allowforced = self:CallHook("CanPlayerEnter",ply)
        if allowed==false and not allowforced then
            return
        end
        if IsValid(ply.door) and ply.door~=self then
            ply.door:PlayerExit(ply,true,true)
        end
        self.occupants[ply]=true
        net.Start("Doors-EnterExit")
            net.WriteBool(true)
            net.WriteEntity(ply)
            net.WriteEntity(self)
            net.WriteEntity(self.interior)
        net.Broadcast()
        ply.door = self
        ply.doori = self.interior
        if IsValid(self.interior) then
            local portals=self.interior.portals
            if (not notp) and portals and self.interior.Fallback then
                ply:SetPos(self:ResolveFallbackPos(ply, false))
                local ang=wp.TransformPortalAngle(ply:EyeAngles(),portals.exterior,portals.interior)
                local fwd=wp.TransformPortalAngle(ply:GetVelocity():Angle(),portals.exterior,portals.interior):Forward()
                ply:SetEyeAngles(Angle(ang.p,ang.y,0))
                ply:SetLocalVelocity(fwd*ply:GetVelocity():Length())
            end
        else
            ply:Spectate(OBS_MODE_ROAMING)
        end
        self:CallHook("PlayerEnter", ply, notp)
        if IsValid(self.interior) then
            self.interior:CallHook("PlayerEnter", ply, notp)
        end
    end

    ---@api
    ---@param ply Player
    ---@param forced boolean?
    ---@param notp boolean?
    function ENT:PlayerExit(ply,forced,notp)
        if self:CallHook("CanPlayerExit",ply)==false and (not forced) then
            return
        end
        self:CallHook("PlayerExit", ply, forced, notp)
        if IsValid(self.interior) then
            self.interior:CallHook("PlayerExit", ply, forced, notp)
        end
        if not IsValid(self.interior) then
            -- spectator mode doesn't exit properly without respawning
            local pos,ang=ply:GetPos(),ply:EyeAngles()
            local hp,armor=ply:Health(),ply:Armor()
            local weps={}
            local ammo={}
            for _,v in pairs(ply:GetWeapons()) do
                table.insert(weps, v:GetClass())
                local p=v:GetPrimaryAmmoType()
                local s=v:GetSecondaryAmmoType()
                if p ~= -1 then
                    ammo[p]=ply:GetAmmoCount(p)
                end
                if s ~= -1 then
                    ammo[s]=ply:GetAmmoCount(s)
                end
            end
            local activewep
            if IsValid(ply:GetActiveWeapon()) then
                activewep=ply:GetActiveWeapon():GetClass()
            end
            ply:Spectate(OBS_MODE_NONE)
            ply:Spawn()
            ply:SetPos(pos)
            ply:SetEyeAngles(ang)
            ply:SetHealth(hp)
            ply:SetArmor(armor)
            for _,v in pairs(weps) do
                ply:Give(tostring(v))
            end
            for k,v in pairs(ammo) do
                ply:SetAmmo(v,k)
            end
            if activewep then
                ply:SelectWeapon(activewep)
            end
            ply.doors_cooldowncur=CurTime()+1
        end
        --if ply:InVehicle() then ply:ExitVehicle() end
        self.occupants[ply]=nil
        net.Start("Doors-EnterExit")
            net.WriteBool(false)
            net.WriteEntity(ply)
            net.WriteEntity(self)
            net.WriteEntity(self.interior)
        net.Broadcast()
        ply.door = nil
        ply.doori = nil
        if not notp and self.Fallback then
            ply:SetPos(self:ResolveFallbackPos(ply, true))
            if IsValid(self.interior) then
                local portals=self.interior.portals
                if (not forced) and portals then
                    local ang=wp.TransformPortalAngle(ply:EyeAngles(),portals.interior,portals.exterior)
                    local fwd=wp.TransformPortalAngle(ply:GetVelocity():Angle(),portals.interior,portals.exterior):Forward()
                    ply:SetEyeAngles(Angle(ang.p,ang.y,0))
                    ply:SetLocalVelocity(fwd*ply:GetVelocity():Length())
                end
            end
        end
        self:CallHook("PostPlayerExit", ply, forced, notp)
        if IsValid(self.interior) then
            self.interior:CallHook("PostPlayerExit", ply, forced, notp)
        end
    end

    ENT:AddHook("Think", "players", function(self)
        for k in pairs(self.occupants) do
            if not IsValid(self.interior) then
                k:SetPos(self:GetPos())
            end
        end
    end)

    ENT:AddHook("PlayerInitialize", "players", function(self)
        net.WriteTable(self.occupants)
    end)
else
    net.Receive("Doors-EnterExit", function()
        local enter=net.ReadBool()
        local ply=net.ReadEntity() --[[@as Player]]
        local ext=net.ReadEntity() --[[@as gmod_door_exterior]]
        local int=net.ReadEntity() --[[@as gmod_door_interior]]

        if not IsValid(ply) then return end
        
        if enter then
            ply.door=ext
            ply.doori=int
            if IsValid(ext) then
                ext.occupants[ply]=true
            end
        else
            ply.door=nil
            ply.doori=nil
            if IsValid(ext) then
                ext.occupants[ply]=nil
            end
        end

        if IsValid(ext) and ext._init then
            if enter then
                ext:CallHook("PlayerEnter", ply)
            else
                ext:CallHook("PlayerExit", ply)
            end
        end

        if IsValid(int) and int._init then
            if enter then
                int:CallHook("PlayerEnter", ply)
            else
                int:CallHook("PlayerExit", ply)
            end
        end
    end)

    ENT:AddHook("PlayerInitialize", "players", function(self)
        self.occupants = net.ReadTable()
    end)

    -- Predicted entry (SetupMove): set the player's door fields immediately so the
    -- interior renders this frame - the predicted crossing can land before the server
    -- catches up. The Doors-EnterExit broadcast re-sets the same fields soon after.
    ENT:AddHook("PostTeleportPortal", "predict", function(self, portal, ent)
        if ent ~= LocalPlayer() then return end
        if not IsValid(self.interior) then return end
        ent.door = self
        ent.doori = self.interior
        self.occupants[ent] = true
        -- Predict the entry unstick so the landing matches the server's. ResolveSafePos
        -- is pure, so re-running it each resim is safe; if not stuck client-side it just
        -- defers to the server.
        local int = self.interior
        if int:IsStuck(ent) then
            ---@type Vector?
            local safe = int:ResolveSafePos(ent, false)
            if safe then ent:SetPos(safe) end
        end
    end)
end

-- Shared (not server-only) so a downstream consumer's CanPlayerEnter veto can
-- predict on the client during world-portals' SetupMove teleport.
ENT:AddHook("ShouldTeleportPortal", "players", function(self,portal,ent)
    if IsValid(ent) and ent:IsPlayer() and self:CallHook("CanPlayerEnter",ent)==false then
        return false
    end
end)
