include('shared.lua')

function ENT:Draw()
    if self._init and self:CallHook("ShouldDraw")~=false then
        if self:CallHook("PreDraw") == false then return end
        if self.CustomDrawModel then
            self:CustomDrawModel()
        else
            self:DrawModel()
        end
        if WireLib then
            -- ENT.Base is base_wire_entity only when Wire is mounted, so the analyzer
            -- resolves the non-Wire branch and can't see us as a wire entity here
            ---@diagnostic disable-next-line: infer-unknown
            Wire_Render(self)
        end
        self:CallHook("Draw")
    end
end

net.Receive("DoorsI-Initialize", function(len)
    local int=net.ReadEntity() --[[@as gmod_door_interior]]
    local ext=net.ReadEntity() --[[@as gmod_door_exterior]]
    local ply=net.ReadEntity() --[[@as Player]]
    local intpos=net.ReadVector()
    if not IsValid(int) then return end
    int:SetPos(intpos)
    if IsValid(ext) then
        int.exterior=ext
        if IsValid(ply) then
            Doors:SetupOwner(int,ply)
        end
        int.phys=int:GetPhysicsObject()
        int._ready=true
        int._init=ext._ready
        ext._init=int._init
        int:CallHook("PlayerInitialize")
        if int._init then
            ext:CallHook("Initialize")
            int:CallHook("Initialize")
            ext:CallHook("PostInitialize")
            int:CallHook("PostInitialize")
        end
    end
end)
function ENT:Initialize()
    net.Start("DoorsI-Initialize") net.WriteEntity(self) net.SendToServer()
    self.nextslowthink=0
end

function ENT:Think()
    if self._init then
        self:CallHook("Think",FrameTime())
        if CurTime()>=self.nextslowthink then
            self.nextslowthink=CurTime()+1
            self:CallHook("SlowThink")
        end
    end
end