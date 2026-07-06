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
            Wire_Render(self)
        end
        self:CallHook("Draw")
    end
end

net.Receive("Doors-Initialize", function(len)
    local ext=net.ReadEntity()
    local int=net.ReadEntity()
    local ply=net.ReadEntity()
    if IsValid(ext) and IsValid(ply) then
        ext.interior=int
        Doors:SetupOwner(ext,ply)
        ext.phys=ext:GetPhysicsObject()
        ext._ready=true
        if IsValid(int) then
            ext._init=int._ready
            int._init=ext._init
        else
            ext._init = true
        end
        ext:CallHook("PlayerInitialize")
        if ext._init then
            ext:CallHook("Initialize")
            ext:CallHook("PostInitialize")
            if IsValid(int) then
                int:CallHook("Initialize")
                int:CallHook("PostInitialize")
            end
        end
    end
end)
function ENT:Initialize()
    net.Start("Doors-Initialize") net.WriteEntity(self) net.SendToServer()
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