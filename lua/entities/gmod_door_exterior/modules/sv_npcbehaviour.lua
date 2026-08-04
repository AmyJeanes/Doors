-- NPC behaviour

local SCAN_RADIUS = 5000 -- how far around the exterior we look for NPCs that saw the player

local IGNORE_PLAYERS = GetConVar("ai_ignoreplayers")
local MOVE_CAPS = bit.bor(CAP_MOVE_GROUND, CAP_MOVE_FLY)

-- Exclude NPCs that don't have the movement capability (e.g. turrets) as they are usually robots
-- and don't have "grudges" in the same way as normal NPCs.
---@param npc NPC
---@return boolean
local function can_pursue(npc)
    return bit.band(npc:CapabilitiesGet(), MOVE_CAPS) ~= 0
end

-- Calculate NPC disposition toward the exterior based on its occupants
---@param self gmod_door_exterior
---@param npc NPC
---@return integer disposition
---@return integer priority
local function target_disposition(self, npc)
    -- https://wiki.facepunch.com/gmod/Enums/D
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
local function revert_npc(self, npc)
    npc:AddEntityRelationship(self, D_NU, 1)
    npc:ClearEnemyMemory(self)
end

---@param self gmod_door_exterior
local function disarm(self)
    if next(self.targeting_npcs) == nil then return end
    for npc in pairs(self.targeting_npcs) do
        if IsValid(npc) then
            revert_npc(self, npc)
        end
    end
    self.targeting_npcs = {}
end

-- Apply grudges to NPCs that saw the player enter the exterior, so they target the exterior instead of the player
---@param self gmod_door_exterior
local function apply_grudges(self)
    local affected = self.targeting_npcs
    for _, ent in ipairs(ents.FindInSphere(self:GetPos(), SCAN_RADIUS)) do
        if ent:IsNPC() then
            local npc = ent --[[@as NPC]]
            if npc:Disposition(self) == D_NU then
                local want, prio = target_disposition(self, npc)
                if want ~= D_NU then
                    npc:AddEntityRelationship(self, want, prio)
                    affected[npc] = true
                end
            end
        end
    end
end

---@api
function ENT:ClearNPCTargeting()
    if not self.NPCsTargetExterior then return end
    disarm(self)
end

ENT:AddHook("Initialize", "npcbehaviour", function(self)
    if not self.NPCsTargetExterior then return end
    self.targeting_npcs = {}
    self:AddFlags(FL_OBJECT) -- makes the exterior visible to NPCs as a potential target
end)


-- Make NPCs forget the player after entering so they don't look up to the player in the interior in the sky
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


ENT:AddHook("PostPlayerExit", "npcbehaviour", function(self)
    if table.IsEmpty(self.occupants) then
        disarm(self)
    end
end)
