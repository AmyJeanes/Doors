---@meta

-- Falco's Prop Protection Interface (CPPI). Optional runtime dependency — guarded
-- with `if CPPI then` at every call site. https://github.com/Facepunch/garrysmod/blob/master/garrysmod/lua/includes/modules/cppi.lua

---@class CPPI
CPPI = {}

---@class Entity
---@field CPPISetOwner fun(self: Entity, ply: Player): boolean
