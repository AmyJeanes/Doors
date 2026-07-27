---@meta

-- Type annotations only - never executed. The declarations below define real
-- globals and library functions with empty bodies, so loading this file at
-- runtime would replace working functions with stubs rather than declare them.
-- It lives outside lua/ so the game cannot reach it; this is the backstop.
error("cppi.lua contains type annotations only and must never be executed")

-- Falco's Prop Protection Interface (CPPI). Optional runtime dependency — guarded
-- with `if CPPI then` at every call site. https://github.com/Facepunch/garrysmod/blob/master/garrysmod/lua/includes/modules/cppi.lua

---@class CPPI
CPPI = {}

---@class Entity
---@field CPPISetOwner fun(self: Entity, ply: Player): boolean