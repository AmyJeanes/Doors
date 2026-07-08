---@class gmod_door_interior : Entity
---@field Model string
---@field exterior gmod_door_exterior
---@field Portal doors_portal_side?
---@field CustomPortals table<string, doors_custom_portal>?
---@field FalseWorldWindows table<string, doors_portal_side>?
---@field initqueue table

ENT.Type = "anim"
if WireLib then
    ENT.Base            = "base_wire_entity"
else
    ENT.Base            = "base_gmodentity"
end
ENT.Author          = "Dr. Matt"
ENT.RenderGroup     = RENDERGROUP_OPAQUE
ENT.DoorInterior    = true

-- Hook system for modules
local hooks={}

---@api
---@param name string
---@param id string
---@param func fun(self: gmod_door_interior, ...): any?
-- >>> GENERATED hook overloads - do not edit; regen: scripts/generate-hook-types.ps1 >>>
---@overload fun(self: gmod_door_interior, name: "BodygroupChanged", id: string, func: fun(self: gmod_door_interior, bodygroup: number, value: number, ...))
---@overload fun(self: gmod_door_interior, name: "Cordon", id: string, func: fun(self: gmod_door_interior, class: string, v: Entity, ...))
---@overload fun(self: gmod_door_interior, name: "CustomData", id: string, func: fun(self: gmod_door_interior, customData: table, ...))
---@overload fun(self: gmod_door_interior, name: "Draw", id: string, func: fun(self: gmod_door_interior, ...))
---@overload fun(self: gmod_door_interior, name: "Initialize", id: string, func: fun(self: gmod_door_interior, ...))
---@overload fun(self: gmod_door_interior, name: "NoCollidePortal", id: string, func: fun(self: gmod_door_interior, portal: linked_portal_door, ent: Entity, ...))
---@overload fun(self: gmod_door_interior, name: "OnRemove", id: string, func: fun(self: gmod_door_interior, ...))
---@overload fun(self: gmod_door_interior, name: "PlayerEnter", id: string, func: fun(self: gmod_door_interior, ply: Player, notp: boolean?, ...))
---@overload fun(self: gmod_door_interior, name: "PlayerExit", id: string, func: fun(self: gmod_door_interior, ply: Player, forced: boolean?, notp: boolean?, ...))
---@overload fun(self: gmod_door_interior, name: "PlayerInitialize", id: string, func: fun(self: gmod_door_interior, ply: Player, ...))
---@overload fun(self: gmod_door_interior, name: "PostDrawCordonProp", id: string, func: fun(self: gmod_door_interior, arg1: Entity, flags: number, ...))
---@overload fun(self: gmod_door_interior, name: "PostDrawPlayer", id: string, func: fun(self: gmod_door_interior, ply: Player, ...))
---@overload fun(self: gmod_door_interior, name: "PostDrawPortal", id: string, func: fun(self: gmod_door_interior, portal: linked_portal_door, ...))
---@overload fun(self: gmod_door_interior, name: "PostDrawTranslucentRenderables", id: string, func: fun(self: gmod_door_interior, ...))
---@overload fun(self: gmod_door_interior, name: "PostInitialize", id: string, func: fun(self: gmod_door_interior, ...))
---@overload fun(self: gmod_door_interior, name: "PostPlayerExit", id: string, func: fun(self: gmod_door_interior, ply: Player, forced: boolean?, notp: boolean?, ...))
---@overload fun(self: gmod_door_interior, name: "PostPlayerInitialize", id: string, func: fun(self: gmod_door_interior, ply: Player, ...))
---@overload fun(self: gmod_door_interior, name: "PostRenderPortal", id: string, func: fun(self: gmod_door_interior, portal: linked_portal_door, depth: number, ...))
---@overload fun(self: gmod_door_interior, name: "PostTeleportPortal", id: string, func: fun(self: gmod_door_interior, portal: linked_portal_door, ent: Entity, newpos: Vector, newang: Angle, ...))
---@overload fun(self: gmod_door_interior, name: "PreDraw", id: string, func: fun(self: gmod_door_interior, ...))
---@overload fun(self: gmod_door_interior, name: "PreDrawCordonProp", id: string, func: fun(self: gmod_door_interior, arg1: Entity, flags: number, ...))
---@overload fun(self: gmod_door_interior, name: "PreDrawPlayer", id: string, func: fun(self: gmod_door_interior, ply: Player, ...))
---@overload fun(self: gmod_door_interior, name: "PreDrawPortal", id: string, func: fun(self: gmod_door_interior, portal: linked_portal_door, ...))
---@overload fun(self: gmod_door_interior, name: "PreDrawTranslucentRenderables", id: string, func: fun(self: gmod_door_interior, ...))
---@overload fun(self: gmod_door_interior, name: "PreInitialize", id: string, func: fun(self: gmod_door_interior, ...))
---@overload fun(self: gmod_door_interior, name: "PreOnRemove", id: string, func: fun(self: gmod_door_interior, ...))
---@overload fun(self: gmod_door_interior, name: "PreRenderPortal", id: string, func: fun(self: gmod_door_interior, portal: linked_portal_door, depth: number, ...))
---@overload fun(self: gmod_door_interior, name: "SetupOwner", id: string, func: fun(self: gmod_door_interior, ply: Player, ...))
---@overload fun(self: gmod_door_interior, name: "SetupPosition", id: string, func: fun(self: gmod_door_interior, res: any, ...))
---@overload fun(self: gmod_door_interior, name: "ShouldAllowThickPortal", id: string, func: fun(self: gmod_door_interior, portal: linked_portal_door, ...))
---@overload fun(self: gmod_door_interior, name: "ShouldDraw", id: string, func: fun(self: gmod_door_interior, ...))
---@overload fun(self: gmod_door_interior, name: "ShouldDrawCordonProp", id: string, func: fun(self: gmod_door_interior, prop: Entity, arg2: any, ...))
---@overload fun(self: gmod_door_interior, name: "ShouldDrawGhost", id: string, func: fun(self: gmod_door_interior, ent: Entity, ghost: Entity, portal: linked_portal_door, exit: linked_portal_door, ...))
---@overload fun(self: gmod_door_interior, name: "ShouldDrawPlayer", id: string, func: fun(self: gmod_door_interior, ply: Player, localply: Player, ...))
---@overload fun(self: gmod_door_interior, name: "ShouldRemoveProp", id: string, func: fun(self: gmod_door_interior, k: any, ...))
---@overload fun(self: gmod_door_interior, name: "ShouldRenderPortal", id: string, func: fun(self: gmod_door_interior, portal: linked_portal_door, exit: linked_portal_door, origin: Vector, ...))
---@overload fun(self: gmod_door_interior, name: "ShouldTeleportPortal", id: string, func: fun(self: gmod_door_interior, portal: linked_portal_door, ent: Entity, ...))
---@overload fun(self: gmod_door_interior, name: "ShouldThinkFast", id: string, func: fun(self: gmod_door_interior, ...))
---@overload fun(self: gmod_door_interior, name: "ShouldTracePortal", id: string, func: fun(self: gmod_door_interior, portal: linked_portal_door, ...))
---@overload fun(self: gmod_door_interior, name: "SkinChanged", id: string, func: fun(self: gmod_door_interior, i: number, ...))
---@overload fun(self: gmod_door_interior, name: "SlowThink", id: string, func: fun(self: gmod_door_interior, ...))
---@overload fun(self: gmod_door_interior, name: "StuckFilter", id: string, func: fun(self: gmod_door_interior, ...))
---@overload fun(self: gmod_door_interior, name: "Think", id: string, func: fun(self: gmod_door_interior, arg1: number, ...))
---@overload fun(self: gmod_door_interior, name: "TraceFilterPortal", id: string, func: fun(self: gmod_door_interior, portal: linked_portal_door, ...))
---@overload fun(self: gmod_door_interior, name: "Use", id: string, func: fun(self: gmod_door_interior, a: Entity, c: Entity, ...))
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
    folder="entities/gmod_door_interior/"..folder.."/"
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
    self:CallHook("OnRemove")
end
