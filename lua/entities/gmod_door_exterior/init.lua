AddCSLuaFile('cl_init.lua')
AddCSLuaFile('shared.lua')
include('shared.lua')

---@param ply Player
---@param tr TraceResult
---@param ClassName string
---@param customData table?
function ENT:SpawnFunction(ply, tr, ClassName, customData)
    local SpawnPos
    if tr and tr.Hit then
        SpawnPos = tr.HitPos + tr.HitNormal
    elseif customData then
        SpawnPos = customData.pos
    end
    if SpawnPos == nil then return end

    local ent = ents.Create( ClassName )
    if not IsValid(ent) then error("entity creation failed: " .. ClassName) end
    -- SpawnFunction is invoked with this SENT's own classname
    ---@cast ent gmod_door_exterior
    ent:SetPos(SpawnPos)
    local ang=Angle(0, (ply:GetPos()-SpawnPos):Angle().y, 0)
    ent:SetAngles(ang)
    if customData then
        ent:CallHook("CustomData", customData)
    end
    Doors:SetupOwner(ent,ply)
    ent:Spawn()
    ent:Activate()
    return ent
end

---@param ply Player
function ENT:InitializePlayer(ply)
    net.Start("Doors-Initialize")
        net.WriteEntity(self)
        net.WriteEntity(self.interior)
        net.WriteEntity(self:GetCreator())
        self:CallHook("PlayerInitialize",ply)
    net.Send(ply)
    self:CallHook("PostPlayerInitialize",ply)
end

util.AddNetworkString("Doors-Initialize")
net.Receive("Doors-Initialize", function(len,ply)
    local ext=net.ReadEntity()
    if IsValid(ext) and ext.DoorExterior then
        if ext.intready then
            ext:InitializePlayer(ply)
        else
            ext.initqueue[ply]=true
        end
    end
end)

ENT:AddHook("InteriorReady","interior",function(self)
    if self.initqueue then
        for k in pairs(self.initqueue) do
            self:InitializePlayer(k)
        end
        self.initqueue=nil
    end
end)

function ENT:Initialize()
    self:SetModel(self.Model)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetRenderMode(RENDERMODE_NORMAL)
    self:SetUseType(SIMPLE_USE)
    
    self.phys = self:GetPhysicsObject()
    if (self.phys:IsValid()) then
        self.phys:Wake()
    end
    
    self.occupants={}
    self.initqueue={}
    self.lastthink=CurTime()
    self.nextslowthink=CurTime()
    
    self:CallHook("Initialize")
    self._init = true
    self:CallHook("PostInitialize")
end

---@param ph PhysObj
function ENT:PhysicsUpdate(ph)
    self:CallHook("PhysicsUpdate", ph)
end

function ENT:Think()
    for k in pairs(self.occupants) do
        if not k or not IsValid(k) then
            self.occupants[k]=nil
        end
    end

    local now = CurTime()
    self:CallHook("Think", now - self.lastthink)
    self.lastthink = now

    if self._init and now >= self.nextslowthink then
        self.nextslowthink = now + 1
        self:CallHook("SlowThink")
    end

    if self:CallHook("ShouldThinkFast") then
        self:NextThink(now)
        return true
    end
end
