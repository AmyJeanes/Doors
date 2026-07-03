---@class gmod_door_exterior : Entity
---@field Model string
---@field Fallback table?
---@field interior gmod_door_interior?
---@field Portal doors_portal_side?
---@field initqueue table

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

---@param func fun(self: gmod_door_exterior, ...): any?
function ENT:AddHook(name,id,func)
    if not (hooks[name]) then hooks[name]={} end
    if hooks[name][id] then error("Duplicate hook ID '"..id.."' for '"..name.."' hook",2) end
    if type(id)==func or not func then error("Invalid parameters - need name, id and func",2) end
    hooks[name][id]=func
end

function ENT:RemoveHook(name,id)
    if hooks[name] and hooks[name][id] then
        hooks[name][id]=nil
    end
end

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

function ENT:Use(a,c)
    self:CallHook("Use",a,c)
end

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
