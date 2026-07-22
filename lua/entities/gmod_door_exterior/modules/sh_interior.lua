-- Adds an interior

CreateConVar("doors_interior_tries", 10000, {FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY}, "Doors - How many tries to find a valid interior placement")

if SERVER then
    -- Skip spots inside map props with no collision (e.g. 3D-skybox scenery) - the trace can't see
    -- them, so the interior would otherwise spawn embedded in one. Brush entities (e.g. *0 *1 *2)
    -- are ignored as they're part of map geometry or are non-visual e.g. worldspawn, triggers, etc.
    ---@param pos Vector
    ---@param mins Vector
    ---@param maxs Vector
    local function mapPropInBox(pos, mins, maxs)
        for _,v in ipairs(ents.FindInBox(pos+mins, pos+maxs)) do
            if v:CreatedByMap() then
                local m = v:GetModel()
                if m and m~="" and string.sub(m,1,1)~="*" then
                    return true
                end
            end
        end
        return false
    end

    ---@param e gmod_door_interior
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
        td.mask=MASK_PLAYERSOLID
        local max=16384
        local tries=GetConVar("doors_interior_tries"):GetInt()
        local targetframetime=1/30
        local nowhere
        local highest
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
            if ((not highest) or (highest and nowhere.z>highest.z))
                and (not util.TraceHull(td --[[@as HullTrace]]).Hit)
                and (self:CallHook("AllowInteriorPos",nil,nowhere,td.mins,td.maxs)~=false)
                and not mapPropInBox(nowhere,td.mins,td.maxs)
            then
                highest = nowhere
            end
        end
        return highest
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
                ---@cast self.interior gmod_door_interior
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
        if not IsValid(e) then error("entity creation failed: " .. self.Interior) end
        -- self.Interior names an interior door class
        ---@cast e gmod_door_interior
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
        for k in pairs(self.occupants) do
            self:PlayerExit(k,true)
            for int in pairs(Doors:GetInteriors()) do
                int:CheckPlayer(k)
            end
        end
    end)
else
    ENT:AddHook("SlowThink","interior",function(self)
        local inside
        for k in pairs(Doors:GetInteriors()) do
            if k:PositionInside(self:GetPos()) then
                inside=k
                break
            end
        end
        if inside and IsValid(inside) then
            local contains = inside.contains
            if self.insideof~=inside then
                if IsValid(self.insideof) and self.insideof.contains then
                    self.insideof.contains[self]=nil
                end
                self.insideof=inside
            end
            if contains then
                contains[self]=true
            end
        elseif IsValid(self.insideof) and self.insideof.contains then
            self.insideof.contains[self]=nil
            self.insideof=nil
        end
    end)
    
    ENT:AddHook("OnRemove","interior",function(self)
        for k in pairs(Doors:GetInteriors()) do
            if k.contains and k.contains[self] then
                k.contains[self] = nil
            end
        end
    end)
end
