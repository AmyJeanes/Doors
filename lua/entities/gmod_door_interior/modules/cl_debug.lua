-- Debug
-- This module file lives under modules/ for the load mechanism but is fully commented out.

--[[
local wireframe=Material("models/wireframe")
ENT:AddHook("Draw", "debug", function(self)
    local mins=self.mins or self:OBBMins()
    local maxs=self.maxs or self:OBBMaxs()
    render.SetMaterial(wireframe)
    render.DrawBox(self:GetPos(),self:GetAngles(),mins,maxs,Color(255,0,0,255),false)
end)

hook.Add("PostDrawTranslucentRenderables","doors-debug",function()
    --local pos = EyePos()+(EyeAngles():Forward()*5000)
    local pos = Vector(-8071.000000,9359.000000,16379.000000)
    local td={}
    td.start = pos
    td.endpos = pos
    td.mins = Vector(-1730.036499, -1594.614258, -298.696838)
    td.maxs = Vector(651.660767, 652.510803, 596.147461)
    local tr=util.TraceHull(td)
    cam.Start2D()
        draw.DrawText(tostring(tr.Hit),"DermaLarge",0,0,Color(255,255,255),TEXT_ALIGN_LEFT)
    cam.End2D()
    if tr.Hit then
        render.SetMaterial(wireframe)
        render.DrawBox(tr.HitPos,Angle(),td.mins,td.maxs,Color(255,0,0,255),false)
    end
end)
]]--