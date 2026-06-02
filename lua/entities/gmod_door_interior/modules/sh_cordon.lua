-- Cordon

---@class gmod_door_interior
---@field props table<Entity, boolean|integer>

ENT:AddHook("Initialize", "cordon", function(self)
    self.props={}
    self.propscan=0
    if not (self.mins and self.maxs) then
        self.mins,self.maxs=self:OBBMins()*0.95, self:OBBMaxs()*0.95
    end
end)

local blacklist={
    ["player"] = true,
    ["viewmodel"] = true
}

ENT:AddHook("Cordon", "cordon", function(self,class,ent)
    if ent.DoorInterior then return false end
end)

function ENT:UpdateCordon()
    for _,v in pairs(ents.FindInBox(self:LocalToWorld(self.mins),self:LocalToWorld(self.maxs))) do
        local check=true
        local class=v:GetClass()
        if blacklist[class] or self:CallHook("Cordon",class,v)==false then
            check=false
        end
        local p=v:GetParent()
        if IsValid(p) then
            local pclass=p:GetClass()
            if blacklist[pclass] or self:CallHook("Cordon",pclass,p)==false then
                check=false
            end
        end
        if self.props[v]==nil and v:GetNoDraw() then
            check=false
        end
        if check then
            -- if not self.props[v] then
            --     print("enter",v)
            -- end
            self.props[v]=1
            -- Back-ref for world-portals' wp-shouldghost (below): marks v as a
            -- real prop we only hide locally, so it stays ghostable while
            -- straddling a portal. Class-agnostic -- works for any cordon
            -- subclass (gmod_tardis_interior etc.); the handler re-validates
            -- membership, so a stale ref after the prop leaves is harmless.
            v.DoorsCordonOwner=self
        end
    end
    for k,v in pairs(self.props) do
        if IsValid(k) then
            if v==true then -- left
                k:SetNoDraw(false)
                self.props[k]=nil
                -- Clear the world-portals back-ref (set above) now this prop has
                -- left the cordon. Guarded on == self: if the prop moved into
                -- another overlapping cordon, that one has already re-stamped the
                -- owner, and we must not clobber its claim.
                if k.DoorsCordonOwner==self then
                    k.DoorsCordonOwner=nil
                end
                -- print("exit",k)
            elseif v==1 then
                self.props[k]=true
            end
        else
            self.props[k]=nil
        end
    end
end

if SERVER then
    ENT:AddHook("PostInitialize","cordon",function(self)
        self:UpdateCordon()
        for k in pairs(self.props) do
            if k.DoorsPhysicsFrozen then
                k.DoorsPhysicsFrozen = false
                local kph = k:GetPhysicsObject()
                if IsValid(kph) then
                    kph:EnableMotion(true)
                end
            end
        end
    end)
end

ENT:AddHook("OnRemove", "cordon", function(self)
    if self.props then
        self:UpdateCordon()
        for k in pairs(self.props) do
            if IsValid(k) then
                -- print("onremove",k)
                if SERVER then
                    if self:CallHook("ShouldRemoveProp",k) ~= false then
                        k:Remove()
                    else
                        local kph = k:GetPhysicsObject()
                        if IsValid(kph) then
                            k.DoorsPhysicsFrozen = kph:IsMotionEnabled()
                            kph:EnableMotion(false)
                        end
                    end
                else
                    k:SetNoDraw(false)
                end
                if k.DoorsCordonOwner==self then
                    k.DoorsCordonOwner=nil
                end
                self.props[k]=nil
            end
        end
    end
end)

if CLIENT then
    ENT:AddHook("Think", "cordon", function(self)
        if CurTime()>self.propscan then
            self.propscan=CurTime()+1
            self:UpdateCordon()
        end
        local inside=LocalPlayer().doori==self or self.contains[LocalPlayer().door] or false
        for k in pairs(self.props) do
            if IsValid(k) and k:GetNoDraw()==inside then
                -- Need to do this every frame unfortunately as GMod resets it really fast
                k:SetNoDraw(not inside)
            end
        end
    end)

    ENT:AddHook("PlayerEnter", "cordon", function(self)
        self:UpdateCordon()
    end)
    
    ENT:AddHook("PlayerExit", "cordon", function(self)
        self:UpdateCordon()
    end)

    ENT:AddHook("PostTeleportPortal", "cordon", function(self,portal,ent)
        self:UpdateCordon()
    end)

    ENT:AddHook("PreRenderPortal", "cordon", function(self,portal,depth)
        if portal ~= self.portals.interior then return end
        if depth > 1 then return end
        for k in pairs(self.props) do
            if IsValid(k) then
                k.olddraw=k:GetNoDraw()
                k:SetNoDraw(true)
            end
        end
    end)

    ENT:AddHook("PostRenderPortal", "cordon", function(self,portal,depth)
        if portal ~= self.portals.interior then return end
        if depth > 1 then return end
        for k in pairs(self.props) do
            if IsValid(k) and k.olddraw~=nil then
                k:SetNoDraw(k.olddraw)
                k.olddraw=nil
            end
        end
    end)

    -- world-portals renders a prop straddling a portal as two clipped halves
    -- (real + clientside ghost). It skips client-NoDraw'd props by default, but
    -- our cordon SetNoDraw(true)'s interior props while the player is OUTSIDE the
    -- interior even though they're real server-side. Opt those back in so a prop
    -- half-through the door still shows its emerged half out the exterior.
    -- DoorsCordonOwner is set in UpdateCordon; re-validate membership here so a
    -- prop that has since left the cordon (stale ref) isn't wrongly claimed.
    hook.Add("wp-shouldghost", "doors_cordon", function(ent)
        local owner = ent.DoorsCordonOwner
        if IsValid(owner) and owner.props and owner.props[ent] then return true end
    end)
end
