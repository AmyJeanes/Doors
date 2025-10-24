-- Handles portals for rendering, thanks to bliptec (http://facepunch.com/member.php?u=238641) for being a babe

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
        if not (int and ext) then return end
        self.portals={}
        self.portals.exterior=ents.Create("linked_portal_door")
        self.portals.interior=ents.Create("linked_portal_door")
        
        -- Exterior Portal
        self.portals.exterior:SetWidth(ext.width)
        self.portals.exterior:SetHeight(ext.height)
        self.portals.exterior:SetPos(self.exterior:LocalToWorld(ext.pos))
        self.portals.exterior:SetAngles(self.exterior:LocalToWorldAngles(ext.ang))
        self.portals.exterior:SetExit(self.portals.interior)
        self.portals.exterior:SetParent(self.exterior)

        if ext.link then
            self.portals.exterior:SetCustomLink(ext.link)
        end

        if ext.exit_point_offset then
            self.portals.exterior:SetExitPosOffset(ext.exit_point_offset.pos)
            self.portals.exterior:SetExitAngOffset(ext.exit_point_offset.ang)
        elseif ext.exit_point then
            self.portals.exterior:SetExitPosOffset(ext.exit_point.pos - ext.pos)
            self.portals.exterior:SetExitAngOffset(ext.exit_point.ang - ext.ang)
        end

        if ext.thickness then
            self.portals.exterior:SetThickness(ext.thickness)
        end

        if ext.inverted then
            self.portals.exterior:SetInverted(ext.inverted)
        end

        if ext.model then
            self.portals.exterior:SetModel(ext.model)
        end

        if ext.model_offset then
            self.portals.exterior:SetModelPos(ext.model_offset.pos)
            self.portals.exterior:SetModelAng(ext.model_offset.ang)
        end

        self.portals.exterior.exterior = self.exterior
        self.portals.exterior.interior = self
        self.portals.exterior:Spawn()
        self.portals.exterior:Activate()
        
        -- interior Portal
        self.portals.interior:SetWidth(int.width)
        self.portals.interior:SetHeight(int.height)
        self.portals.interior:SetPos(self:LocalToWorld(int.pos))
        self.portals.interior:SetAngles(self:LocalToWorldAngles(int.ang))
        self.portals.interior:SetExit(self.portals.exterior)
        self.portals.interior:SetParent(self)

        if int.link then
            self.portals.interior:SetCustomLink(int.link)
        end

        if int.exit_point_offset then
            self.portals.interior:SetExitPosOffset(int.exit_point_offset.pos)
            self.portals.interior:SetExitAngOffset(int.exit_point_offset.ang)
        elseif int.exit_point then
            self.portals.interior:SetExitPosOffset(int.exit_point.pos - int.pos)
            self.portals.interior:SetExitAngOffset(int.exit_point.ang - int.ang)
        end
        
        if int.thickness then
            self.portals.interior:SetThickness(int.thickness)
        end

        if int.inverted then
            self.portals.interior:SetInverted(int.inverted)
        end

        if int.model then
            self.portals.interior:SetModel(int.model)
        end

        if int.model_offset then
            self.portals.interior:SetModelPos(int.model_offset.pos)
            self.portals.interior:SetModelAng(int.model_offset.ang)
        end

        self.portals.interior.interior = self
        self.portals.interior.exterior = self.exterior
        self.portals.interior:Spawn()
        self.portals.interior:Activate()

        if self.CustomPortals then
            self.customportals={}
            for k,v in pairs(self.CustomPortals) do
                self.customportals[k] = {}
                local portals = self.customportals[k]
                portals.entry=ents.Create("linked_portal_door")
                portals.exit=ents.Create("linked_portal_door")

                -- Entry Portal
                portals.entry:SetWidth(v.entry.width)
                portals.entry:SetHeight(v.entry.height)
                portals.entry:SetPos(self:LocalToWorld(v.entry.pos))
                portals.entry:SetAngles(self:LocalToWorldAngles(v.entry.ang))
                portals.entry:SetExit(portals.exit)
                portals.entry:SetParent(self)

                if v.entry.link then
                    portals.entry:SetCustomLink(v.entry.link)
                end

                if v.entry.exit_point_offset then
                    portals.entry:SetExitPosOffset(v.entry.exit_point_offset.pos)
                    portals.entry:SetExitAngOffset(v.entry.exit_point_offset.ang)
                elseif v.entry.exit_point then
                    portals.entry:SetExitPosOffset(v.entry.exit_point.pos - v.entry.pos)
                    portals.entry:SetExitAngOffset(v.entry.exit_point.ang - v.entry.ang)
                end

                if v.entry.thickness then
                    portals.entry:SetThickness(v.entry.thickness)
                end

                if v.entry.inverted then
                    portals.entry:SetInverted(v.entry.inverted)
                end

                if v.entry.model then
                    portals.entry:SetModel(v.entry.model)
                end

                if v.entry.model_offset then
                    portals.entry:SetModelPos(v.entry.model_offset.pos)
                    portals.entry:SetModelAng(v.entry.model_offset.ang)
                end

                portals.entry.exterior = self.exterior
                portals.entry.interior = self
                portals.entry.black = v.entry.black
                portals.entry.fallback = v.entry.fallback
                portals.entry:Spawn()
                portals.entry:Activate()

                -- Exit Portal
                portals.exit:SetWidth(v.exit.width)
                portals.exit:SetHeight(v.exit.height)
                portals.exit:SetPos(self:LocalToWorld(v.exit.pos))
                portals.exit:SetAngles(self:LocalToWorldAngles(v.exit.ang))
                portals.exit:SetExit(portals.entry)
                portals.exit:SetParent(self)

                if v.exit.link then
                    portals.exit:SetCustomLink(v.exit.link)
                end

                if v.exit.exit_point_offset then
                    portals.exit:SetExitPosOffset(v.exit.exit_point_offset.pos)
                    portals.exit:SetExitAngOffset(v.exit.exit_point_offset.ang)
                elseif v.exit.exit_point then
                    portals.exit:SetExitPosOffset(v.exit.exit_point.pos - v.exit.pos)
                    portals.exit:SetExitAngOffset(v.exit.exit_point.ang - v.exit.ang)
                end

                if v.exit.thickness then
                    portals.exit:SetThickness(v.exit.thickness)
                end

                if v.exit.inverted then
                    portals.exit:SetInverted(v.exit.inverted)
                end

                if v.exit.model then
                    portals.exit:SetModel(v.exit.model)
                end

                if v.exit.model_offset then
                    portals.exit:SetModelPos(v.exit.model_offset.pos)
                    portals.exit:SetModelAng(v.exit.model_offset.ang)
                end


                portals.exit.interior = self
                portals.exit.exterior = self.exterior
                portals.exit.black = v.exit.black
                portals.exit.fallback = v.exit.fallback
                portals.exit:Spawn()
                portals.exit:Activate()
            end
        end
    end)

    ENT:AddHook("PostTeleportPortal", "portals", function(self,portal,ent)
        if portal~=self.portals.interior and portal.fallback and ent:IsPlayer() and self:IsStuck(ent) then
            ent:SetPos(self:LocalToWorld(portal.fallback))
        end
    end)

    hook.Add("wp-shouldtp","doors-portals",function(portal,ent)
        local p = portal:GetParent()
        if IsValid(p) and (p.DoorInterior or p.DoorExterior) and p._init then
            return p:CallHook("ShouldTeleportPortal",portal,ent)
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
            for i=1,count do
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
        local insideof = IsValid(wp.drawingent) and wp.drawingent.exterior and wp.drawingent.exterior.insideof==self and wp.drawingent.interior.portals.interior==wp.drawingent
        if wp.drawing and wp.drawingent==self.portals.interior and not (wp.drawingent==self.portals.interior and self.props[self.exterior]) and (not insideof) then
            return false
        end
        if wp.drawing and wp.drawingent.interior and wp.drawingent.interior ~= self and wp.drawingent.exterior and wp.drawingent.exterior.insideof~=self then
            return false
        end
    end)

    ENT:AddHook("ShouldRenderPortal", "portals", function(self)
        if LocalPlayer().doori~=self then
            return false
        end
    end)
    
    hook.Add("wp-shouldrender", "doors-portals", function(portal,exit,origin)
        local p=portal:GetParent()
        if IsValid(p) then
            if p.DoorExterior or p.DoorInterior then
                if not p._init then return false end
                return p:CallHook("ShouldRenderPortal",portal,exit,origin)
            end
        end
    end)
    
    hook.Add("wp-predraw","doors-portals",function(portal)
        local p=portal:GetParent()
        if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
            p:CallHook("PreDrawPortal",portal)
        end
    end)
    
    hook.Add("wp-postdraw","doors-portals",function(portal)
        local p=portal:GetParent()
        if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
            p:CallHook("PostDrawPortal",portal)
        end
    end)

    hook.Add("wp-prerender","doors-portals",function(portal)
        local p=portal:GetParent()
        if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
            p:CallHook("PreRenderPortal",portal)
        end
    end)
    
    hook.Add("wp-postrender","doors-portals",function(portal)
        local p=portal:GetParent()
        if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
            p:CallHook("PostRenderPortal",portal)
        end
    end)

    hook.Add("wp-allowthickportal","doors-portals",function(portal)
        local p=portal:GetParent()
        if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
            return p:CallHook("ShouldAllowThickPortal",portal)
        end
    end)
end

hook.Add("wp-trace", "doors-portals", function(portal)
    local p=portal:GetParent()
    if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
        return p:CallHook("ShouldTracePortal",portal)
    end
end)

hook.Add("wp-tracefilter", "doors-portals", function(portal)
    local p=portal:GetParent()
    if IsValid(p) and (p.DoorExterior or p.DoorInterior) and p._init then
        return p:CallHook("TraceFilterPortal",portal)
    end
end)

hook.Add("wp-teleport","doors-portals",function(portal,ent,newpos,newang)
    local p=portal:GetParent()
    if IsValid(p) and (p.DoorInterior or p.DoorExterior) and p._init then
        return p:CallHook("PostTeleportPortal",portal,ent,newpos,newang)
    end
end)
