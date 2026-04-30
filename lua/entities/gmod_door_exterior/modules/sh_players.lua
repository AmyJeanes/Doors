-- Handles players

if SERVER then
    util.AddNetworkString("Doors-EnterExit")
    
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
                local newpos = self.interior:LocalToWorld(self.interior.Fallback.pos)
                local height = ply:OBBMaxs().z
                local temppos = Vector(0,0,height)
                temppos:Rotate(Angle(0,0,self.interior:GetAngles().r))
                newpos = newpos + Vector(0,0,(temppos.z - height) / 2)
                ply:SetPos(newpos)
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
            local newpos = self:LocalToWorld(self.Fallback.pos)
            local height = ply:OBBMaxs().z
            local temppos = Vector(0,0,height)
            temppos:Rotate(Angle(0,0,self:GetAngles().r))
            newpos = newpos + Vector(0,0,(temppos.z - height) / 2)
            ply:SetPos(newpos)
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

    ENT:AddHook("ShouldTeleportPortal", "players", function(self,portal,ent)
        if IsValid(ent) and ent:IsPlayer() and self:CallHook("CanPlayerEnter",ent)==false then
            return false
        end
    end)

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
        local ply=net.ReadEntity()
        local ext=net.ReadEntity()
        local int=net.ReadEntity()

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

        if ply~=LocalPlayer() then return end
        
        if IsValid(ext) and ext._init then
            if enter then
                ext:CallHook("PlayerEnter")
            else
                ext:CallHook("PlayerExit")
            end
        end
        
        if IsValid(int) and int._init then
            if enter then
                int:CallHook("PlayerEnter")
            else
                int:CallHook("PlayerExit")
            end
        end
    end)

    ENT:AddHook("PlayerInitialize", "players", function(self)
        self.occupants = net.ReadTable()
    end)
end
