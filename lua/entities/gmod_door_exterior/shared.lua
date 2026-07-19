---@class gmod_door_exterior : Entity
---@field Model string
---@field Fallback table?
---@field interior gmod_door_interior?
---@field insideof gmod_door_interior? interior this shell is parked inside, when it is nested in one
---@field Portal doors_portal_side?
---@field doorway doors_portal_side? geometry-only copy, networked to the client at player init
---@field initqueue table
---@field _creatorsteamid string?

ENT.Type = "anim"
if WireLib then
    ENT.Base            = "base_wire_entity"
else
    ENT.Base            = "base_gmodentity"
end
ENT.Author          = "Dr. Matt"
ENT.RenderGroup     = RENDERGROUP_BOTH
ENT.DoorExterior    = true
ENT.Interior        = "gmod_door_interior"

-- Hook system for modules
local hooks={}

---@api
---@param name string
---@param id string
---@param func fun(self: gmod_door_exterior, ...): any?
-- >>> GENERATED hook overloads - do not edit; regen: scripts/generate-hook-types.ps1 >>>
---@overload fun(self: gmod_door_exterior, name: "AllowInteriorPos", id: string, func: fun(self: gmod_door_exterior, arg1: any, nowhere: Vector, arg3: Vector, arg4: Vector, ...))
---@overload fun(self: gmod_door_exterior, name: "BodygroupChanged", id: string, func: fun(self: gmod_door_exterior, bodygroup: number, value: number, ...))
---@overload fun(self: gmod_door_exterior, name: "CanPlayerEnter", id: string, func: fun(self: gmod_door_exterior, ply: Player, ...))
---@overload fun(self: gmod_door_exterior, name: "CanPlayerExit", id: string, func: fun(self: gmod_door_exterior, ply: Player, ...))
---@overload fun(self: gmod_door_exterior, name: "CustomData", id: string, func: fun(self: gmod_door_exterior, customData: table, ...))
---@overload fun(self: gmod_door_exterior, name: "Draw", id: string, func: fun(self: gmod_door_exterior, ...))
---@overload fun(self: gmod_door_exterior, name: "FindingPosition", id: string, func: fun(self: gmod_door_exterior, e: gmod_door_interior, creator: Player, ...))
---@overload fun(self: gmod_door_exterior, name: "FindingPositionFailed", id: string, func: fun(self: gmod_door_exterior, arg1: gmod_door_interior, creator: Player, res: any, ...))
---@overload fun(self: gmod_door_exterior, name: "FoundPosition", id: string, func: fun(self: gmod_door_exterior, arg1: gmod_door_interior, creator: Player, ...))
---@overload fun(self: gmod_door_exterior, name: "Initialize", id: string, func: fun(self: gmod_door_exterior, ...))
---@overload fun(self: gmod_door_exterior, name: "InteriorReady", id: string, func: fun(self: gmod_door_exterior, arg1: gmod_door_interior, ...))
---@overload fun(self: gmod_door_exterior, name: "NoCollidePortal", id: string, func: fun(self: gmod_door_exterior, portal: linked_portal_door, ent: Entity, ...))
---@overload fun(self: gmod_door_exterior, name: "OnRemove", id: string, func: fun(self: gmod_door_exterior, ...))
---@overload fun(self: gmod_door_exterior, name: "PhysicsUpdate", id: string, func: fun(self: gmod_door_exterior, ph: PhysObj, ...))
---@overload fun(self: gmod_door_exterior, name: "PlayerEnter", id: string, func: fun(self: gmod_door_exterior, ply: Entity, ...))
---@overload fun(self: gmod_door_exterior, name: "PlayerExit", id: string, func: fun(self: gmod_door_exterior, ply: Entity, ...))
---@overload fun(self: gmod_door_exterior, name: "PlayerInitialize", id: string, func: fun(self: gmod_door_exterior, ply: Player, ...))
---@overload fun(self: gmod_door_exterior, name: "PostDrawPortal", id: string, func: fun(self: gmod_door_exterior, portal: linked_portal_door, ...))
---@overload fun(self: gmod_door_exterior, name: "PostInitialize", id: string, func: fun(self: gmod_door_exterior, ...))
---@overload fun(self: gmod_door_exterior, name: "PostPlayerExit", id: string, func: fun(self: gmod_door_exterior, ply: Player, forced: boolean?, notp: boolean?, ...))
---@overload fun(self: gmod_door_exterior, name: "PostPlayerInitialize", id: string, func: fun(self: gmod_door_exterior, ply: Player, ...))
---@overload fun(self: gmod_door_exterior, name: "PostRenderPortal", id: string, func: fun(self: gmod_door_exterior, portal: linked_portal_door, depth: number, ...))
---@overload fun(self: gmod_door_exterior, name: "PostTeleportPortal", id: string, func: fun(self: gmod_door_exterior, portal: linked_portal_door, ent: Entity, newpos: Vector, newang: Angle, ...))
---@overload fun(self: gmod_door_exterior, name: "PreDraw", id: string, func: fun(self: gmod_door_exterior, ...))
---@overload fun(self: gmod_door_exterior, name: "PreDrawPortal", id: string, func: fun(self: gmod_door_exterior, portal: linked_portal_door, ...))
---@overload fun(self: gmod_door_exterior, name: "PreInitialize", id: string, func: fun(self: gmod_door_exterior, ...))
---@overload fun(self: gmod_door_exterior, name: "PreOnRemove", id: string, func: fun(self: gmod_door_exterior, ...))
---@overload fun(self: gmod_door_exterior, name: "PreRenderPortal", id: string, func: fun(self: gmod_door_exterior, portal: linked_portal_door, depth: number, ...))
---@overload fun(self: gmod_door_exterior, name: "SetupOwner", id: string, func: fun(self: gmod_door_exterior, ply: Player, ...))
---@overload fun(self: gmod_door_exterior, name: "ShouldAllowThickPortal", id: string, func: fun(self: gmod_door_exterior, portal: linked_portal_door, ...))
---@overload fun(self: gmod_door_exterior, name: "ShouldDraw", id: string, func: fun(self: gmod_door_exterior, ...))
---@overload fun(self: gmod_door_exterior, name: "ShouldDrawGhost", id: string, func: fun(self: gmod_door_exterior, ent: Entity, ghost: Entity, portal: linked_portal_door, exit: linked_portal_door, ...))
---@overload fun(self: gmod_door_exterior, name: "ShouldGhostPortal", id: string, func: fun(self: gmod_door_exterior, portal: linked_portal_door, ent: Entity, ...))
---@overload fun(self: gmod_door_exterior, name: "ShouldRenderPortal", id: string, func: fun(self: gmod_door_exterior, portal: linked_portal_door, exit: linked_portal_door, origin: Vector, ...))
---@overload fun(self: gmod_door_exterior, name: "ShouldSpawnInterior", id: string, func: fun(self: gmod_door_exterior, ...))
---@overload fun(self: gmod_door_exterior, name: "ShouldTeleportPortal", id: string, func: fun(self: gmod_door_exterior, portal: linked_portal_door, ent: Entity, ...))
---@overload fun(self: gmod_door_exterior, name: "ShouldThinkFast", id: string, func: fun(self: gmod_door_exterior, ...))
---@overload fun(self: gmod_door_exterior, name: "ShouldTracePortal", id: string, func: fun(self: gmod_door_exterior, portal: linked_portal_door, ...))
---@overload fun(self: gmod_door_exterior, name: "SkinChanged", id: string, func: fun(self: gmod_door_exterior, i: number, ...))
---@overload fun(self: gmod_door_exterior, name: "SlowThink", id: string, func: fun(self: gmod_door_exterior, ...))
---@overload fun(self: gmod_door_exterior, name: "Think", id: string, func: fun(self: gmod_door_exterior, arg1: number, ...))
---@overload fun(self: gmod_door_exterior, name: "TraceFilterPortal", id: string, func: fun(self: gmod_door_exterior, portal: linked_portal_door, ...))
---@overload fun(self: gmod_door_exterior, name: "Use", id: string, func: fun(self: gmod_door_exterior, a: Entity, c: Entity, ...))
-- <<< END GENERATED hook overloads <<<
function ENT:AddHook(name,id,func)
    if not (hooks[name]) then hooks[name]={} end
    if hooks[name][id] then error("Duplicate hook ID '"..id.."' for '"..name.."' hook",2) end
    if type(id)==func or not func then error("Invalid parameters - need name, id and func",2) end
    hooks[name][id]=func
end

---@api
---@param name string
---@param id string
function ENT:RemoveHook(name,id)
    if hooks[name] and hooks[name][id] then
        hooks[name][id]=nil
    end
end

---@api
---@param name string
---@return any
function ENT:CallHook(name,...)
    if not hooks[name] then return end
    local a,b,c,d,e,f
    for _,v in pairs(hooks[name]) do
        a,b,c,d,e,f = v(self,...)
        if a ~= nil then
            return a,b,c,d,e,f
        end
    end
end

---@api
---@param folder string
---@param addonly boolean?
---@param noprefix boolean?
function ENT:LoadFolder(folder,addonly,noprefix)
    folder="entities/gmod_door_exterior/"..folder.."/"
    local modules = file.Find(folder.."*.lua","LUA")
    for _, plugin in ipairs(modules) do
        if noprefix then
            if SERVER then
                AddCSLuaFile(folder..plugin)
            end
            if not addonly then
                include(folder..plugin)
            end
        else
            local prefix = string.Left( plugin, string.find( plugin, "_" ) - 1 )
            if (CLIENT and (prefix=="sh" or prefix=="cl")) then
                if not addonly then
                    include(folder..plugin)
                end
            elseif (SERVER) then
                if (prefix=="sv" or prefix=="sh") and (not addonly) then
                    include(folder..plugin)
                end
                if (prefix=="sh" or prefix=="cl") then
                    AddCSLuaFile(folder..plugin)
                end
            end
        end
    end
end
ENT:LoadFolder("modules/libraries") -- loaded before main modules
ENT:LoadFolder("modules")

---@param a Entity
---@param c Entity
function ENT:Use(a,c)
    self:CallHook("Use",a,c)
end

---@param fullUpdate boolean
function ENT:OnRemove(fullUpdate)
    if fullUpdate then
        return -- https://wiki.facepunch.com/gmod/ENTITY:OnRemove#clientsidebehaviourremarks
    end
    self:CallHook("PreOnRemove")
    if IsValid(self.interior) then
        self.interior:CallHook("PreOnRemove")
    end
    self:CallHook("OnRemove")
end
