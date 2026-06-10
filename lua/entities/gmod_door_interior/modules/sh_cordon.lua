-- Cordon

---@class gmod_door_interior
---@field props table<Entity, boolean|integer>
---@field cordonhidden boolean?

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
        -- Don't adopt entities something else has hidden (e.g. world-portals' NoDraw'd,
        -- unparented collision frames); first-sight only, since our gate never NoDraws a prop.
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
    -- One RenderOverride slot, up to three owners inner to outer: a pre-existing foreign
    -- override, this cordon gate, then world-portals' ghost clip. cordonRender[prop] holds
    -- our claim, cleared explicitly on leave/removal; __mode="k" (weak keys) is a backstop -
    -- the GC eventually reaps entries whose prop was collected, so a missed path can't leak.
    -- (Entity userdata is reaped only a while after removal, hence the explicit clear too.)
    -- Weak tables: https://www.lua.org/pil/17.html
    local cordonRender = setmetatable({}, { __mode = "k" })

    -- Visibility derived fresh per render pass (never stored): hidden in the open world
    -- from outside, shown inside; shown looking through the exterior door, hidden looking
    -- out the interior door; hidden during a consumer's own RT via cordonhidden.
    local function cordonShouldDraw(interior)
        if not IsValid(interior) then return false end
        if interior.cordonhidden then return false end
        if wp.drawing then
            local rp = wp.drawingent
            local portals = interior.portals
            if portals then
                if rp == portals.exterior then return true end
                if rp == portals.interior then return false end
            end
        end
        return LocalPlayer().doori == interior
            or (interior.contains and interior.contains[LocalPlayer().door])
            or false
    end

    -- Chain whatever override we displaced so another system's look is preserved.
    local function drawBase(self, flags, rec)
        local base = rec.base
        if base and base ~= rec.override then base(self, flags) else self:DrawModel(flags) end
    end

    local function makeCordonOverride(rec)
        return function(self, flags)
            if cordonShouldDraw(rec.interior) then drawBase(self, flags, rec) end
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

    -- Hand our base back if we still own the slot, or drop it into a ghost-owned slot for
    -- the ghost to re-capture next frame. If a foreign override displaced us, leave it alone.
    function ENT:ReleaseCordonRender(prop)
        local rec = cordonRender[prop]
        if not rec or rec.interior ~= self then return end
        if IsValid(prop) and (prop.RenderOverride == rec.override or wp.IsGhosting(prop)) then
            prop.RenderOverride = rec.base
        end
        cordonRender[prop] = nil
    end

    ENT:AddHook("Think", "cordon", function(self)
        if CurTime()>self.propscan then
            self.propscan=CurTime()+1
            self:UpdateCordon()
        end
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
