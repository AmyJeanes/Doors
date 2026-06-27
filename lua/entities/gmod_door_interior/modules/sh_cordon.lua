-- Cordon

---@class gmod_door_interior
---@field props table<Entity, boolean|integer>
---@field cordonhidden boolean?

ENT:AddHook("Initialize", "cordon", function(self)
    self.props={}
    if not (self.mins and self.maxs) then
        self.mins,self.maxs=self:OBBMins()*0.95, self:OBBMaxs()*0.95
    end
end)

local blacklist={
    ["player"] = true,
    ["viewmodel"] = true,
    ["predicted_viewmodel"] = true
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
            self.props[v]=1
        end
    end
    for k,v in pairs(self.props) do
        if IsValid(k) then
            if v==true then -- left
                if CLIENT then self:ReleaseCordonRender(k) end
                self.props[k]=nil
            elseif v==1 then
                self.props[k]=true
            end
        else
            if CLIENT then self:ReleaseCordonRender(k) end
            self.props[k]=nil
        end
    end
end

ENT:AddHook("SlowThink", "cordon", function(self)
    self:UpdateCordon()
end)

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
                    self:ReleaseCordonRender(k)
                end
                self.props[k]=nil
            end
        end
    end
end)

if CLIENT then
    -- A prop has one RenderOverride slot, but up to three things layer onto it, inner to outer:
    -- an override already there, this cordon, then world-portals' ghost. cordonRender tracks the
    -- props we've claimed; we clear a prop's entry ourselves when it leaves or gets deleted.
    -- { __mode = "k" } tells Lua our entry here doesn't count as a reason to keep a prop alive, so
    -- if nothing else references a prop once it's gone, Lua quietly drops our entry too. That's a
    -- backstop for a missed cleanup though - it's slow for entities, so our own clearing keeps it tidy.
    local cordonRender = setmetatable({}, { __mode = "k" })

    -- Recomputed each render pass, never cached - it depends on which view is drawing.
    local function cordonShouldDraw(interior)
        if not IsValid(interior) then return false end
        -- hidden during a consumer's own RT
        if interior.cordonhidden then return false end
        if wp.drawing then
            local rp = wp.drawingent
            local portals = interior.portals
            if portals then
                -- looking in through the exterior door: show our props
                if rp == portals.exterior then return true end
                -- looking out the interior door: hide our props
                if rp == portals.interior then
                    -- unless our exterior is parked inside another interior (self-nested / TARDIS-in-TARDIS),
                    -- where looking out shows that interior, so our props should draw
                    if IsValid(interior.exterior) and IsValid(interior.exterior.insideof) then return true end
                    return false
                end
            end
        end
        -- otherwise: shown only when the player is inside
        return interior:LocalPlayerInside()
    end

    -- Chain whatever override we displaced so another system's look is preserved.
    local function drawBase(self, flags, rec)
        local base = rec.base
        if base and base ~= rec.override then
            base(self, flags)
            -- A chained override can nil ours and skip its own draw on the frame it tears
            -- down - GMod's spawn-effect RenderParent does exactly this when the 0.5s effect
            -- ends. Draw the model ourselves and re-take the slot so the prop doesn't blip
            -- the frame before the next Think re-adopts it.
            if self.RenderOverride ~= rec.override then
                self:DrawModel(flags)
                rec.base = nil
                self.RenderOverride = rec.override
            end
        else
            self:DrawModel(flags)
        end
    end

    local function makeCordonOverride(rec)
        return function(self, flags)
            local interior = rec.interior
            if not cordonShouldDraw(interior) then return end
            interior:CallHook("PreDrawCordonProp", self, flags)
            drawBase(self, flags, rec)
            interior:CallHook("PostDrawCordonProp", self, flags)
        end
    end

    -- Install/repair our override on a prop we own. Yield while the ghost owns the slot
    -- (it chains us via its saved override); re-capture if a foreign override displaced us.
    function ENT:EnsureCordonRender(prop)
        if wp.IsGhosting(prop) then return end
        local rec = cordonRender[prop]
        if rec and rec.interior ~= self then return end -- another cordon owns it
        if not rec then
            rec = { interior = self }
            rec.override = makeCordonOverride(rec)
            rec.base = prop.RenderOverride
            prop.RenderOverride = rec.override
            cordonRender[prop] = rec
        elseif prop.RenderOverride ~= rec.override then
            rec.base = prop.RenderOverride
            prop.RenderOverride = rec.override
        end
    end

    -- Release our claim on the prop's single RenderOverride slot. If we still own it, put back
    -- whatever override sat under us. If the ghost owns it now, write that override in anyway:
    -- next frame the ghost re-captures the slot and chains to it instead of to us. If a foreign
    -- override displaced us, leave it alone - the slot is no longer ours to restore.
    function ENT:ReleaseCordonRender(prop)
        local rec = cordonRender[prop]
        if not rec or rec.interior ~= self then return end
        if IsValid(prop) and (prop.RenderOverride == rec.override or wp.IsGhosting(prop)) then
            prop.RenderOverride = rec.base
        end
        cordonRender[prop] = nil
    end

    ENT:AddHook("Think", "cordon", function(self)
        for k in pairs(self.props) do
            if IsValid(k) then
                self:EnsureCordonRender(k)
            end
        end
    end)

    ENT:AddHook("PlayerEnter", "cordon", function(self)
        self:UpdateCordon()
    end)

    ENT:AddHook("PlayerExit", "cordon", function(self)
        self:UpdateCordon()
    end)

    ENT:AddHook("PostTeleportPortal", "cordon", function(self)
        self:UpdateCordon()
    end)
end
