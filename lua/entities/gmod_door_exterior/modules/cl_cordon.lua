-- Cordon

ENT:AddHook("PreRenderPortal", "cordon", function(self,portal)
    if (not self.interior) or portal ~= self.interior.portals.exterior then return end
    for k in pairs(self.interior.props) do
        if IsValid(k) then
            k.olddraw=k:GetNoDraw()
            k:SetNoDraw(false)
        end
    end
end)

ENT:AddHook("PostRenderPortal", "cordon", function(self,portal)
    if (not self.interior) or portal ~= self.interior.portals.exterior then return end
    for k in pairs(self.interior.props) do
        if IsValid(k) and k.olddraw~=nil then
            k:SetNoDraw(k.olddraw)
            k.olddraw=nil
        end
    end
end)