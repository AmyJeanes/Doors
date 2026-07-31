---@meta

-- Type annotations only - never executed. The declarations below define real
-- globals and library functions with empty bodies, so loading this file at
-- runtime would replace working functions with stubs rather than declare them.
-- It lives outside lua/ so the game cannot reach it; this is the backstop.
error("wire.lua contains type annotations only and must never be executed")

-- Wiremod is an optional runtime dependency and is not on workspace.library, so the
-- surface Doors touches is declared here instead.

---@param ent Entity
function Wire_Render(ent) end
