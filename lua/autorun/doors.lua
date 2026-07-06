-- Doors

---@class Doors
Doors=Doors or {}
---@api
---@param folder string?
---@param addonly boolean?
---@param noprefix boolean?
function Doors:LoadFolder(folder,addonly,noprefix)
    if folder then
        folder="doors/"..folder.."/"
    else
        folder="doors/"
    end
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
Doors:LoadFolder("libraries/libraries")
Doors:LoadFolder("libraries")
Doors:LoadFolder()