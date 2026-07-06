AddCSLuaFile('cl_init.lua')
AddCSLuaFile('shared.lua')
include('shared.lua')

---@param ply Player
---@param tr WPTraceResult
---@param ClassName string
function ENT:SpawnFunction( ply, tr, ClassName )
    if not tr.Hit then return end
    local SpawnPos = tr.HitPos + tr.HitNormal
    local ent = ents.Create( ClassName )
    ent:SetPos(SpawnPos)
    local ang=Angle(0, (ply:GetPos()-SpawnPos):Angle().y, 0)
    ent:SetAngles(ang)
    Doors:SetupOwner(ent,ply)
    ent:Spawn()
    ent:Activate()
    return ent
end

---@param ply Player
function ENT:InitializePlayer(ply)
    net.Start("DoorsI-Initialize")
        net.WriteEntity(self)
        net.WriteEntity(self.exterior)
        net.WriteEntity(self:GetCreator())
        net.WriteVector(self:GetPos())
        self:CallHook("PlayerInitialize", ply)
    net.Send(ply)
    self:CallHook("PostPlayerInitialize", ply)
end

util.AddNetworkString("DoorsI-Initialize")
---@param len number
---@param ply Player
net.Receive("DoorsI-Initialize", function(len,ply)
    local int=net.ReadEntity() --[[@as gmod_door_interior]]
    if IsValid(int) then
        if int.spacecheck then
            int.initqueue[ply] = true
        else
            int:InitializePlayer(ply)
        end
    end
end)
function ENT:Initialize()
    if self.spacecheck then
        if not (self.exterior and IsValid(self.exterior)) then
            error("Exterior not set, removing!")
            self:Remove()
        end
        self:SetModel(self.Model)
        self:PhysicsInit(SOLID_VPHYSICS)
        self:SetMoveType(MOVETYPE_VPHYSICS)
        self:SetSolid(SOLID_VPHYSICS)
        self:SetRenderMode(RENDERMODE_NORMAL)
        self:SetUseType(SIMPLE_USE)
        self:DrawShadow(false)
        
        self.phys = self:GetPhysicsObject()
        if (self.phys:IsValid()) then
            self.phys:EnableMotion(false)
        end
        
        self.occupants = {}
        self.lastthink = CurTime()
        self.nextslowthink=CurTime()
        self.initqueue = {}
    else
        self:CallHook("Initialize")
        self._init = true
        self:CallHook("PostInitialize")
    end
end

ENT:AddHook("PostInitialize","interior",function(self)
    if self.initqueue then
        for k in pairs(self.initqueue) do
            self:InitializePlayer(k)
        end
        self.initqueue=nil
    end
end)

function ENT:Think()
    for k in pairs(self.occupants) do
        if not k or not IsValid(k) then
            self.occupants[k]=nil
        end
    end

    self:CallHook("Think",CurTime()-self.lastthink)
    self.lastthink=CurTime()

    if self._init and CurTime() >= self.nextslowthink then
        self.nextslowthink = CurTime() + 1
        self:CallHook("SlowThink")
    end

    if self:CallHook("ShouldThinkFast") then
        self:NextThink(CurTime())
        return true
    end
end
