---@meta

-- Type annotations only - never executed. The declarations below define real
-- globals and library functions with empty bodies, so loading this file at
-- runtime would replace working functions with stubs rather than declare them.
-- It lives outside lua/ so the game cannot reach it; this is the backstop.
error("glua_overrides.lua contains type annotations only and must never be executed")

--- g_ContextMenu is typed as a plain Panel, which knows nothing of the :Open() the sandbox
--- gamemode adds to it. Cast a local to this class to call it.
---@class ContextMenuPanel : Panel
---@field Open fun(self: ContextMenuPanel)