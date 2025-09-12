-- Adds an interior



if SERVER then
    function ENT:FindPosition(e)
        local creator=e:GetCreator()
        if self:CallHook("FindingPosition", e, creator)~=true then
            creator:ChatPrint("Please wait, finding suitable spawn location for interior..")
        end
        coroutine.yield()
        local td={}
        local tdret={}
        td.output=tdret
        td.mins=e.mins or e:OBBMins()
        td.maxs=e.maxs or e:OBBMaxs()
        local td3d={}
        local td3dret={}
        td3d.output = td3dret
        td3d.mask = MASK_SOLID_BRUSHONLY
        local skycam = ents.FindByClass("sky_camera")[1]
        local isskycam = IsValid(skycam)
        if isskycam then
            td3d.endpos = skycam:GetPos()
        end
        local max=16384
        local tries=10000
        local targetframetime=1/30
        local nowhere
        local highest
        local highest3d
        local start=SysTime()
        while tries>0 do
            tries=tries-1
            if (SysTime()-start)>targetframetime then
                coroutine.yield()
                start=SysTime()
            end
            nowhere=Vector(math.random(-max,max),math.random(-max,max),math.random(-max,max))
            td.start=nowhere
            td.endpos=nowhere
            td3d.start=nowhere
            if ((not highest) or (highest and nowhere.z>highest.z))
                and (not util.TraceHull(td).Hit)
                and (self:CallHook("AllowInteriorPos",nil,nowhere,mins,maxs)~=false)
            then
                if isskycam and util.TraceLine(td3d).Hit then
                    highest3d = nowhere
                end
                highest = nowhere
            end
        end
        return highest3d or highest
    end
    
    ENT:AddHook("ShouldThinkFast","interior",function(self)
        if self.findingpos then
            return true
        end
    end)
    
    ENT:AddHook("Think","interior",function(self)
        if self.findingpos then
            local success,res=coroutine.resume(self.findingpos)
            if coroutine.status(self.findingpos)=="dead" or (not success) then
                self.findingpos=nil
                local creator = self:GetCreator()
                if not success or not res then
                    if self:CallHook("FindingPositionFailed", self.interior, creator, res)~=true then
                        if res then
                            creator:ChatPrint("Coroutine error while finding position: "..res)
                        else
                            creator:ChatPrint("WARNING: Unable to locate space for interior, you can try again or use a different map.")
                        end
                    end
                    self.interior:Remove()
                    self.interior=nil
                    self.intready=true
                    self:CallHook("InteriorReady",false)
                    return
                end
                if self:CallHook("FoundPosition", self.interior, creator)~=true then
                    creator:ChatPrint("Done!")
                end
                local newPos = self.interior:CallHook("SetupPosition", res)
                if newPos ~= nil and isvector(newPos) then
                    res = newPos
                end
                self.interior:SetPos(res)
                self:DeleteOnRemove(self.interior)
                self.interior:DeleteOnRemove(self)
                self.interior.occupants=self.occupants -- Hooray for referenced tables
                self.interior=self.interior
                self.interior.spacecheck=nil
                self.interior:SetCollisionGroup(self.interior.oldcollisiongroup)
                self.interior:Initialize()
                self.intready=true
                self:CallHook("InteriorReady",self.interior)
            end
        end
    end)
    
    ENT:AddHook("Initialize", "interior", function(self)
        if self:CallHook("ShouldSpawnInterior") == false then
            self.intready=true
            self:CallHook("InteriorReady",false)
            return
        end
        local e=ents.Create(self.Interior)
        e.spacecheck=true
        e.exterior=self
        e.ID=self.ID
        Doors:SetupOwner(e,self:GetCreator())
        e:Spawn()
        e:Activate()
        e:CallHook("PreInitialize")
        e.oldcollisiongroup = e:GetCollisionGroup()
        e:SetCollisionGroup(COLLISION_GROUP_WORLD)
        self.interior=e
        self.findingpos = coroutine.create(self.FindPosition)
        coroutine.resume(self.findingpos,self,e)
    end)
    
    ENT:AddHook("OnRemove", "interior", function(self)
        for k,v in pairs(self.occupants) do
            self:PlayerExit(k,true)
            for int in pairs(Doors:GetInteriors()) do
                int:CheckPlayer(k)
            end
        end
    end)
else
    ENT:AddHook("SlowThink","interior",function(self)
        local inside
        for k,v in pairs(Doors:GetInteriors()) do
            if k:PositionInside(self:GetPos()) then
                inside=k
                break
            end
        end
        if IsValid(inside) then
            if self.insideof~=inside then
                if IsValid(self.insideof) and self.insideof.contains then
                    self.insideof.contains[self]=nil
                end
                self.insideof=inside
            end
            if inside.contains then
                inside.contains[self]=true
            end
        elseif IsValid(self.insideof) and self.insideof.contains then
            self.insideof.contains[self]=nil
            self.insideof=nil
        end
    end)
    
    ENT:AddHook("OnRemove","interior",function(self)
        for k,v in pairs(Doors:GetInteriors()) do
            if k.contains and k.contains[self] then
                k.contains[self] = nil
            end
        end
    end)
end