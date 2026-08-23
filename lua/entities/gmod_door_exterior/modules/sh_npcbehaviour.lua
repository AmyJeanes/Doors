-- NPC behaviour

---@class npc_heat_entry
---@field disp integer
---@field prio integer
---@field track_until number?

---@class gmod_door_exterior
---@field NPCsTargetExterior boolean? NPCs will target this exterior if they see players go inside it
---@field NPCHeatCooloff number? seconds the pursuit stays hot after all contact is lost before forgetting (default 25)
---@field targeting_npcs table<NPC, npc_heat_entry>
---@field heat_deadline number?
---@field next_heat_tick number?

local HEAT_COOLOFF = 25

local NW_HOT = "NPCHot"
local NW_PURSUERS = "NPCPursuers"
local NW_TRACKING = "NPCTracking"
local NW_HELD = "NPCTrackHeld"
local NW_END = "NPCCooloffEnd"
local NW_DUR = "NPCCooloffDur"

-- True if any NPC is currently looking for or tracking the exterior
---@api
---@return boolean
function ENT:IsHotToNPCs()
    return self:GetNW2Bool(NW_HOT, false)
end

-- Total number of NPCs currently looking for or tracking the exterior
---@api
---@return integer
function ENT:GetNPCPursuerCount()
    return self:GetNW2Int(NW_PURSUERS, 0)
end

-- Total number of NPCs currently tracking the exterior, not just looking for it
---@api
---@return integer
function ENT:GetNPCTrackingCount()
    return self:GetNW2Int(NW_TRACKING, 0)
end

-- True while at least one NPC is currently tracking the exterior
---@api
---@return boolean
function ENT:IsNPCTrackHeld()
    return self:GetNW2Bool(NW_HELD, false)
end

-- CurTime() at which the cool-off ends. 0 when held or not hot
---@api
---@return number
function ENT:GetNPCCooloffEnd()
    return self:GetNW2Float(NW_END, 0)
end

-- Number of seconds the pursuit stays hot after all contact is lost before forgetting
---@api
---@return number
function ENT:GetNPCCooloffDuration()
    return self:GetNW2Float(NW_DUR, HEAT_COOLOFF)
end

if not SERVER then return end

local SCAN_RADIUS = 5000
local HEAT_TICK = 0.1
local HEAT_TRACK_GRACE = 2 -- seconds a freshly (re)acquired pursuer still counts as tracking

local IGNORE_PLAYERS = GetConVar("ai_ignoreplayers")
local MOVE_CAPS = bit.bor(CAP_MOVE_GROUND, CAP_MOVE_FLY)

-- Turrets (no movement capability) only fight what they directly see, so they can't hold grudges and won't pursue
---@param npc NPC
---@return boolean
local function can_pursue(npc)
    return bit.band(npc:CapabilitiesGet(), MOVE_CAPS) ~= 0
end

---@param self gmod_door_exterior
---@param npc NPC
---@return integer disposition
---@return integer priority
local function target_disposition(self, npc)
    if not can_pursue(npc) then return D_NU, 0 end
    if IGNORE_PLAYERS and IGNORE_PLAYERS:GetBool() then return D_NU, 0 end
    local result, result_prio = D_NU, 0
    for ply in pairs(self.occupants) do
        if not ply:IsFlagSet(FL_NOTARGET) and npc:HasEnemyMemory(ply) then
            local disp, prio = npc:Disposition(ply)
            if disp == D_HT then
                return D_HT, prio
            elseif disp == D_FR then
                result, result_prio = D_FR, prio
            end
        end
    end
    return result, result_prio
end

---@param self gmod_door_exterior
---@param npc NPC
local function drop_relationship(self, npc)
    npc:AddEntityRelationship(self, D_NU, 1)
    npc:ClearEnemyMemory(self)
end

---@param self gmod_door_exterior
local function apply_grudges(self)
    local grudged = false
    for _, ent in ipairs(ents.FindInSphere(self:GetPos(), SCAN_RADIUS)) do
        if ent:IsNPC() then
            local npc = ent --[[@as NPC]]
            if npc:Disposition(self) == D_NU then
                local disp, prio = target_disposition(self, npc)
                if disp ~= D_NU then
                    npc:AddEntityRelationship(self, disp, prio)
                    self.targeting_npcs[npc] = { disp = disp, prio = prio, track_until = RealTime() + HEAT_TRACK_GRACE }
                    npc:UpdateEnemyMemory(self, self:GetPos())
                    npc:SetEnemy(self)
                    grudged = true
                end
            end
        end
    end
    if grudged then
        self.heat_deadline = RealTime() + (self.NPCHeatCooloff or HEAT_COOLOFF)
    end
end

---@api
function ENT:ClearNPCTargeting()
    if not self.NPCsTargetExterior then return end
    for npc in pairs(self.targeting_npcs) do
        if IsValid(npc) then drop_relationship(self, npc) end
    end
    -- glua_ls upstream: empty {} rejected against the declared container field type -- https://github.com/Pollux12/gmod-glua-ls/issues/80
    self.targeting_npcs = {} --[[@as table<NPC, npc_heat_entry>]]
end

-- Force all NPCs to "lose" the exterior and stop pursuing it, but grudges still remain until the cooloff expires
-- Useful for when NPCs can see the exterior, but shouldn't care about it e.g. invisible etc
---@api
function ENT:HideFromNPCs()
    if not self.NPCsTargetExterior then return end
    for npc in pairs(self.targeting_npcs) do
        if IsValid(npc) then
            npc:AddEntityRelationship(self, D_NU, 1)
        else
            self.targeting_npcs[npc] = nil
        end
    end
end

-- Re-acquire NPCs with grudges after HideFromNPCs in case they should be able to see it again e.g. no longer invisible
---@api
function ENT:RevealToNPCs()
    if not self.NPCsTargetExterior then return end
    for npc, entry in pairs(self.targeting_npcs) do
        if IsValid(npc) then
            npc:AddEntityRelationship(self, entry.disp, entry.prio)
            entry.track_until = RealTime() + HEAT_TRACK_GRACE -- grace while it re-acquires
        else
            self.targeting_npcs[npc] = nil
        end
    end
end

-- Drop grudges with any NPCs that can not currently see the exterior, e.g. resprayed exterior
---@api
function ENT:NPCExteriorChanged()
    if not self.NPCsTargetExterior then return end
    for npc in pairs(self.targeting_npcs) do
        if not IsValid(npc) then
            self.targeting_npcs[npc] = nil
        elseif not npc:Visible(self) then
            drop_relationship(self, npc)
            self.targeting_npcs[npc] = nil
        end
    end
end

---@param self gmod_door_exterior
local function update_heat(self)
    local now = RealTime()
    local grudged, tracking = 0, 0
    for npc, entry in pairs(self.targeting_npcs) do
        if not IsValid(npc) then
            self.targeting_npcs[npc] = nil
        else
            grudged = grudged + 1
            -- fresh (re)acquire still counts as tracking briefly, so state doesn't flicker off and on while the NPC reacquires the exterior
            if (npc:GetEnemy() == self and npc:Visible(self)) or now < (entry.track_until or 0) then
                tracking = tracking + 1
            end
        end
    end

    local held = tracking > 0
    if held then
        self.heat_deadline = now + (self.NPCHeatCooloff or HEAT_COOLOFF)
    elseif grudged > 0 and now >= (self.heat_deadline or 0) then
        for npc in pairs(self.targeting_npcs) do
            if IsValid(npc) then drop_relationship(self, npc) end
        end
        self.targeting_npcs = {}
        grudged = 0
    end

    self:SetNW2Bool(NW_HOT, grudged > 0)
    self:SetNW2Int(NW_PURSUERS, grudged)
    self:SetNW2Int(NW_TRACKING, tracking)
    self:SetNW2Bool(NW_HELD, held)
    local end_ct = 0
    if not held and grudged > 0 then
        end_ct = math.Round(CurTime() + ((self.heat_deadline or now) - now), 1)
    end
    self:SetNW2Float(NW_END, end_ct)
end

ENT:AddHook("Initialize", "npcbehaviour", function(self)
    if not self.NPCsTargetExterior then return end
    -- glua_ls upstream: empty {} rejected against the declared container field type -- https://github.com/Pollux12/gmod-glua-ls/issues/80
    self.targeting_npcs = {} --[[@as table<NPC, npc_heat_entry>]]
    self:SetNW2Float(NW_DUR, self.NPCHeatCooloff or HEAT_COOLOFF)
    -- FL_OBJECT must be added at Initialize, so NPCs will be able to acquire the exterior as a target, otherwise it will be ignored
    self:AddFlags(FL_OBJECT)
end)

-- Drop the player from NPC grudges instantly so they don't try to look at or follow the player into the invisible interior in the sky
ENT:AddHook("PlayerEnter", "npcbehaviour", function(self, ply)
    if not self.NPCsTargetExterior then return end
    apply_grudges(self)
    for _, ent in ipairs(ents.FindInSphere(self:GetPos(), SCAN_RADIUS)) do
        if ent:IsNPC() then
            local npc = ent --[[@as NPC]]
            npc:ClearEnemyMemory(ply)
        end
    end
end)

-- Network heat so it can be shown on the client as soon as the player enters on e.g. a HUD element
ENT:AddHook("PostPlayerEnter", "npcbehaviour", function(self)
    if not self.NPCsTargetExterior then return end
    update_heat(self)
end)

-- Drop NPC grudges where all players that they had grudges against have left the exterior
ENT:AddHook("PostPlayerExit", "npcbehaviour", function(self)
    if not self.NPCsTargetExterior then return end
    for npc in pairs(self.targeting_npcs) do
        if not IsValid(npc) then
            self.targeting_npcs[npc] = nil
        elseif target_disposition(self, npc) == D_NU then
            drop_relationship(self, npc)
            self.targeting_npcs[npc] = nil
        end
    end
    update_heat(self)
end)

ENT:AddHook("Think", "npcbehaviour", function(self)
    if not self.NPCsTargetExterior then return end
    if next(self.targeting_npcs) == nil then
        if self:GetNW2Bool(NW_HOT) then
            self:SetNW2Bool(NW_HOT, false)
            self:SetNW2Int(NW_PURSUERS, 0)
            self:SetNW2Int(NW_TRACKING, 0)
            self:SetNW2Bool(NW_HELD, false)
            self:SetNW2Float(NW_END, 0)
        end
        return
    end
    local now = RealTime()
    if (self.next_heat_tick or 0) > now then return end
    self.next_heat_tick = now + HEAT_TICK
    update_heat(self)
end)
