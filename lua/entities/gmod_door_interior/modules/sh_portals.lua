-- Handles portals for rendering, thanks to bliptec (http://facepunch.com/member.php?u=238641) for being a babe

---@class doors_portal_side
---@field pos Vector
---@field ang Angle
---@field width number
---@field height number
---@field link string?
---@field exit_point { pos: Vector, ang: Angle }?
---@field exit_point_offset { pos: Vector, ang: Angle }?
---@field thickness number?
---@field inverted boolean?
---@field model string?
---@field model_offset { pos: Vector, ang: Angle }?
---@field black boolean?
---@field fallback Vector?

---@class doors_custom_portal
---@field entry doors_portal_side
---@field exit doors_portal_side

if SERVER then

    ENT:AddHook("PlayerInitialize", "portals", function(self)
        if self.portals then
            net.WriteEntity(self.portals.exterior)
            net.WriteEntity(self.portals.interior)
            if self.customportals then
                net.WriteBool(true)
                net.WriteInt(table.Count(self.customportals),8)
                for k,v in pairs(self.customportals) do
                    net.WriteString(k)
                
                    net.WriteEntity(v.entry)
                    net.WriteBool(v.entry.black)
                
                    net.WriteEntity(v.exit)
                    net.WriteBool(v.exit.black)
                end
            else
                net.WriteBool(false)
            end
        end
    end)
    
    ENT:AddHook("PreInitialize", "portals", function(self)
        local int=self.Portal
        local ext=self.exterior.Portal
        if not int or not ext then return end
        self.portals={}
        local extPortal=ents.Create("linked_portal_door")
        local intPortal=ents.Create("linked_portal_door")
        if not IsValid(extPortal) or not IsValid(intPortal) then error("entity creation failed: linked_portal_door") end
        self.portals.exterior=extPortal
        self.portals.interior=intPortal

        -- Exterior Portal
        extPortal:SetWidth(ext.width)
        extPortal:SetHeight(ext.height)
        extPortal:SetPos(self.exterior:LocalToWorld(ext.pos))
        extPortal:SetAngles(self.exterior:LocalToWorldAngles(ext.ang))
        extPortal:SetExit(intPortal)
        extPortal:SetParent(self.exterior)

        if ext.link then
            extPortal:SetCustomLink(ext.link)
        end

        if ext.exit_point_offset then
            extPortal:SetExitPosOffset(ext.exit_point_offset.pos)
            extPortal:SetExitAngOffset(ext.exit_point_offset.ang)
        elseif ext.exit_point then
            extPortal:SetExitPosOffset(ext.exit_point.pos - ext.pos)
            extPortal:SetExitAngOffset(ext.exit_point.ang - ext.ang)
        end

        if ext.thickness then
            extPortal:SetThickness(ext.thickness)
        end

        if ext.inverted then
            extPortal:SetInverted(ext.inverted)
        end

        if ext.model then
            extPortal:SetCustomModel(ext.model)
        end

        if ext.model_offset then
            extPortal:SetCustomModelPosOffset(ext.model_offset.pos)
            extPortal:SetCustomModelAngOffset(ext.model_offset.ang)
        end

        extPortal.exterior = self.exterior
        extPortal.interior = self
        extPortal:Spawn()
        extPortal:Activate()

        -- interior Portal
        intPortal:SetWidth(int.width)
        intPortal:SetHeight(int.height)
        intPortal:SetPos(self:LocalToWorld(int.pos))
        intPortal:SetAngles(self:LocalToWorldAngles(int.ang))
        intPortal:SetExit(extPortal)
        intPortal:SetParent(self)

        if int.link then
            intPortal:SetCustomLink(int.link)
        end

        if int.exit_point_offset then
            intPortal:SetExitPosOffset(int.exit_point_offset.pos)
            intPortal:SetExitAngOffset(int.exit_point_offset.ang)
        elseif int.exit_point then
            intPortal:SetExitPosOffset(int.exit_point.pos - int.pos)
            intPortal:SetExitAngOffset(int.exit_point.ang - int.ang)
        end

        if int.thickness then
            intPortal:SetThickness(int.thickness)
        end

        if int.inverted then
            intPortal:SetInverted(int.inverted)
        end

        if int.model then
            intPortal:SetCustomModel(int.model)
        end

        if int.model_offset then
            intPortal:SetCustomModelPosOffset(int.model_offset.pos)
            intPortal:SetCustomModelAngOffset(int.model_offset.ang)
        end

        intPortal.interior = self
        intPortal.exterior = self.exterior
        intPortal:Spawn()
        intPortal:Activate()

        if self.CustomPortals then
            self.customportals={}
            for k,v in pairs(self.CustomPortals) do
                ---@cast v doors_custom_portal
                self.customportals[k] = {}
                local portals = self.customportals[k]
                local entryPortal=ents.Create("linked_portal_door")
                local exitPortal=ents.Create("linked_portal_door")
                if not IsValid(entryPortal) or not IsValid(exitPortal) then error("entity creation failed: linked_portal_door") end
                portals.entry=entryPortal
                portals.exit=exitPortal

                -- Entry Portal
                entryPortal:SetWidth(v.entry.width)
                entryPortal:SetHeight(v.entry.height)
                entryPortal:SetPos(self:LocalToWorld(v.entry.pos))
                entryPortal:SetAngles(self:LocalToWorldAngles(v.entry.ang))
                entryPortal:SetExit(exitPortal)
                entryPortal:SetParent(self)

                if v.entry.link then
                    entryPortal:SetCustomLink(v.entry.link)
                end

                if v.entry.exit_point_offset then
                    entryPortal:SetExitPosOffset(v.entry.exit_point_offset.pos)
                    entryPortal:SetExitAngOffset(v.entry.exit_point_offset.ang)
                elseif v.entry.exit_point then
                    entryPortal:SetExitPosOffset(v.entry.exit_point.pos - v.entry.pos)
                    entryPortal:SetExitAngOffset(v.entry.exit_point.ang - v.entry.ang)
                end

                if v.entry.thickness then
                    entryPortal:SetThickness(v.entry.thickness)
                end

                if v.entry.inverted then
                    entryPortal:SetInverted(v.entry.inverted)
                end

                if v.entry.model then
                    entryPortal:SetCustomModel(v.entry.model)
                end

                if v.entry.model_offset then
                    entryPortal:SetCustomModelPosOffset(v.entry.model_offset.pos)
                    entryPortal:SetCustomModelAngOffset(v.entry.model_offset.ang)
                end

                entryPortal.exterior = self.exterior
                entryPortal.interior = self
                entryPortal.black = v.entry.black
                entryPortal.fallback = v.entry.fallback
                entryPortal:Spawn()
                entryPortal:Activate()

                -- Exit Portal
                exitPortal:SetWidth(v.exit.width)
                exitPortal:SetHeight(v.exit.height)
                exitPortal:SetPos(self:LocalToWorld(v.exit.pos))
                exitPortal:SetAngles(self:LocalToWorldAngles(v.exit.ang))
                exitPortal:SetExit(entryPortal)
                exitPortal:SetParent(self)

                if v.exit.link then
                    exitPortal:SetCustomLink(v.exit.link)
                end

                if v.exit.exit_point_offset then
                    exitPortal:SetExitPosOffset(v.exit.exit_point_offset.pos)
                    exitPortal:SetExitAngOffset(v.exit.exit_point_offset.ang)
                elseif v.exit.exit_point then
                    exitPortal:SetExitPosOffset(v.exit.exit_point.pos - v.exit.pos)
                    exitPortal:SetExitAngOffset(v.exit.exit_point.ang - v.exit.ang)
                end

                if v.exit.thickness then
                    exitPortal:SetThickness(v.exit.thickness)
                end

                if v.exit.inverted then
                    exitPortal:SetInverted(v.exit.inverted)
                end

                if v.exit.model then
                    exitPortal:SetCustomModel(v.exit.model)
                end

                if v.exit.model_offset then
                    exitPortal:SetCustomModelPosOffset(v.exit.model_offset.pos)
                    exitPortal:SetCustomModelAngOffset(v.exit.model_offset.ang)
                end


                exitPortal.interior = self
                exitPortal.exterior = self.exterior
                exitPortal.black = v.exit.black
                exitPortal.fallback = v.exit.fallback
                exitPortal:Spawn()
                exitPortal:Activate()
            end
        end

        if self.FalseWorldWindows then
            self.falseworldwindows={}
            for k,v in pairs(self.FalseWorldWindows) do
                ---@cast v doors_portal_side
                local fworld = ents.Create("linked_portal_door")
                if not IsValid(fworld) then error("entity creation failed: linked_portal_door") end
                self.falseworldwindows[k] = fworld

                -- False World Window
                fworld:SetWidth(v.width)
                fworld:SetHeight(v.height)
                fworld:SetPos(self:LocalToWorld(v.pos))
                fworld:SetAngles(self:LocalToWorldAngles(v.ang))
                fworld:SetParent(self)

                if v.exit_point_offset then
                    fworld:SetExitPosOffset(v.exit_point_offset.pos)
                    fworld:SetExitAngOffset(v.exit_point_offset.ang)
                elseif v.exit_point then
                    fworld:SetExitPosOffset(v.exit_point.pos - v.pos)
                    fworld:SetExitAngOffset(v.exit_point.ang - v.ang)
                end

                if v.thickness then
                    fworld:SetThickness(v.thickness)
                end

                if v.inverted then
                    fworld:SetInverted(v.inverted)
                end

                if v.model then
                    fworld:SetCustomModel(v.model)
                end

                if v.model_offset then
                    fworld:SetCustomModelPosOffset(v.model_offset.pos)
                    fworld:SetCustomModelAngOffset(v.model_offset.ang)
                end

                if v.falseworld then
                    fworld:SetFalseWorld(v.falseworld)
                end

                if v.link then
                    fworld:SetCustomLink(v.link)
                end

                fworld.exterior = self.exterior
                fworld.interior = self
                fworld:Spawn()
                fworld:Activate()
            end
        end
    end)

    ENT:AddHook("PostTeleportPortal", "portals", function(self,portal,ent)
        if portal~=self.portals.interior and portal.fallback and ent:IsPlayer() and self:IsStuck(ent) then
            ent:SetPos(self:LocalToWorld(portal.fallback))
        end
    end)
else
    ENT:AddHook("Initialize","interior",function(self)
        self.contains = {}
    end)
    
    ENT:AddHook("PlayerInitialize", "portals", function(self)
        self.portals={}
        local exterior=net.ReadEntity()
        local interior=net.ReadEntity()
        if IsValid(exterior) and IsValid(interior) then
            self.portals.exterior=exterior
            self.portals.exterior.exterior=self.exterior
            self.portals.exterior.interior=self
            
            self.portals.interior=interior
            self.portals.interior.exterior=self.exterior
            self.portals.interior.interior=self
        end
        
        if net.ReadBool() then
            self.customportals={}
            local count=net.ReadInt(8)
            for _=1,count do
                local k=net.ReadString()
                self.customportals[k]={}
                local portals = self.customportals[k]
            
                portals.entry=net.ReadEntity()
                portals.entry.exterior = self.exterior
                portals.entry.interior = self
                portals.entry.black = net.ReadBool()
            
                portals.exit=net.ReadEntity()
                portals.exit.exterior = self.exterior
                portals.exit.interior = self
                portals.exit.black = net.ReadBool()
            end
        end
    end)
    
    ENT:AddHook("ShouldDraw", "portals", function(self)
        if not wp.drawing then return end
        local portal = wp.drawingent
        if not IsValid(portal) then return end
        -- A shell parked inside us (self-nested, or a child interior): its portal sees our room.
        if portal.exterior and portal.exterior.insideof == self then return end
        -- Our interior door shows the world outside, not our room (unless our shell is cordoned in here).
        if portal == self.portals.interior and not self.props[self.exterior] then return false end
        -- Any other portal isn't ours, so it can't be showing our room.
        if portal.interior ~= self then return false end
    end)

    ENT:AddHook("ShouldRenderPortal", "portals", function(self)
        local rp = wp.renderparent
        if self.portals then
            -- looking out our interior door: it shows the exterior, not us
            if rp==self.portals.interior then
                -- unless our exterior is parked inside another interior (self-nested / TARDIS-in-TARDIS),
                -- where looking out shows that interior, so our portals should render there
                if IsValid(self.exterior) and IsValid(self.exterior.insideof) then return end
                return false
            end
            -- looking in our exterior door: our portals should render, even for a non-occupant
            if rp==self.portals.exterior then return end
        end
        -- otherwise (own eye view / open world): only someone inside, or viewing through our camera, sees our portals
        if not self:LocalPlayerInside() and not self:RenderingThroughCordonCamera() then return false end
    end)
    
    ---@param portal linked_portal_door
    ---@param exit linked_portal_door
    ---@param origin Vector
    hook.Add("wp-shouldrender", "doors-portals", function(portal,exit,origin)
        local p=portal:GetParent()
        if IsValid(p) then
            if p.DoorExterior or p.DoorInterior then
                if not p._init then return false end
                return p:CallHook("ShouldRenderPortal",portal,exit,origin)
            end
        end
    end)
    
    ---@param portal linked_portal_door
    hook.Add("wp-predraw","doors-portals",function(portal)
        local p=portal:GetParent()
        if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
            p:CallHook("PreDrawPortal",portal)
        end
    end)
    
    ---@param portal linked_portal_door
    hook.Add("wp-postdraw","doors-portals",function(portal)
        local p=portal:GetParent()
        if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
            p:CallHook("PostDrawPortal",portal)
        end
    end)

    ---@param portal linked_portal_door
    ---@param exitPortal linked_portal_door
    ---@param plyOrigin Vector
    ---@param depth number
    hook.Add("wp-prerender","doors-portals",function(portal,exitPortal,plyOrigin,depth)
        local p=portal:GetParent()
        if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
            p:CallHook("PreRenderPortal",portal,depth)
        end
    end)

    ---@param portal linked_portal_door
    ---@param exitPortal linked_portal_door
    ---@param plyOrigin Vector
    ---@param depth number
    hook.Add("wp-postrender","doors-portals",function(portal,exitPortal,plyOrigin,depth)
        local p=portal:GetParent()
        if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
            p:CallHook("PostRenderPortal",portal,depth)
        end
    end)

    -- Route world-portals' per-draw ghost-draw query to the exit portal's parent,
    -- which hosts the emerged half and decides whether it may draw this pass.
    ---@param ent Entity
    ---@param ghost Entity
    ---@param portal linked_portal_door
    ---@param exit linked_portal_door
    hook.Add("wp-shouldghostdraw","doors-portals",function(ent,ghost,portal,exit)
        local p=IsValid(exit) and exit:GetParent()
        if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
            return p:CallHook("ShouldDrawGhost",ent,ghost,portal,exit)
        end
    end)

    ---@param portal linked_portal_door
    hook.Add("wp-allowthickportal","doors-portals",function(portal)
        local p=portal:GetParent()
        if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
            return p:CallHook("ShouldAllowThickPortal",portal)
        end
    end)
end

-- Shared so world-portals' predicted teleport (SetupMove) can consult it on the
-- client too, not just the server. Forwards to the parent's ShouldTeleportPortal
-- chain; the server stays authoritative.
---@param portal linked_portal_door
---@param ent Entity
hook.Add("wp-shouldtp","doors-portals",function(portal,ent)
    local p = portal:GetParent()
    if IsValid(p) and (p.DoorInterior or p.DoorExterior) and p._init then
        return p:CallHook("ShouldTeleportPortal",portal,ent)
    end
end)

---@param portal linked_portal_door
hook.Add("wp-trace", "doors-portals", function(portal)
    local p=portal:GetParent()
    if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
        return p:CallHook("ShouldTracePortal",portal)
    end
end)

---@param portal linked_portal_door
hook.Add("wp-tracefilter", "doors-portals", function(portal)
    local p=portal:GetParent()
    if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
        return p:CallHook("TraceFilterPortal",portal)
    end
end)

---@param portal linked_portal_door
---@param ent Entity
---@param newpos Vector
---@param newang Angle
hook.Add("wp-teleport","doors-portals",function(portal,ent,newpos,newang)
    local p=portal:GetParent()
    if IsValid(p) and (p.DoorInterior or p.DoorExterior) and p._init then
        return p:CallHook("PostTeleportPortal",portal,ent,newpos,newang)
    end
end)

---@param portal linked_portal_door
---@param ent Entity
hook.Add("wp-nocollide","doors-portals",function(portal,ent)
    local p=portal:GetParent()
    if IsValid(p) and (p.DoorInterior or p.DoorExterior) and p._init then
        return p:CallHook("NoCollidePortal",portal,ent)
    end
end)

---@param portal linked_portal_door
---@param ent Entity
hook.Add("wp-shouldghost","doors-portals",function(portal,ent)
    if ent.DoorInterior or ent.DoorExterior then return false end
    local p=portal:GetParent()
    if IsValid(p) and (p.DoorInterior or p.DoorExterior) and p._init then
        return p:CallHook("ShouldGhostPortal",portal,ent)
    end
end)
