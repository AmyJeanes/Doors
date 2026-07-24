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
            -- glua_ls 1.1.1: ENT.Base is base_wire_entity only when Wire is mounted, so the analyzer
            -- resolves the non-Wire branch and can't see us as a wire entity here
            ---@diagnostic disable-next-line: infer-unknown
            Wire_Render(self)
        end
        self:CallHook("Draw")
    end
end

net.Receive("Doors-Initialize", function(len)
    local ext=net.ReadEntity() --[[@as gmod_door_exterior]]
    local int=net.ReadEntity() --[[@as gmod_door_interior]]
    local ply=net.ReadEntity() --[[@as Player]]
    if IsValid(ext) then
        ext.interior=int
        if IsValid(ply) then
            Doors:SetupOwner(ext,ply)
        end
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