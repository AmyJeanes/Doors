---@meta

-- glua-api-snippets types enum-parameter functions (SetUseType, SetCollisionGroup, ...)
-- with strict literal-union aliases (_USE, COLLISION_GROUP, FCVAR) but types the matching
-- constants as plain `integer`, so passing e.g. SIMPLE_USE trips param-type-mismatch.
-- Re-type each constant we pass as its alias so call sites match. Add a line here when a
-- new strictly-typed enum constant gets used - the LSP flags it the moment it does.
---@type _USE
SIMPLE_USE = 3
---@type COLLISION_GROUP
COLLISION_GROUP_WORLD = 20
---@type FCVAR
FCVAR_ARCHIVE = 128
---@type FCVAR
FCVAR_REPLICATED = 8192
---@type FCVAR
FCVAR_NOTIFY = 256
---@type OBS_MODE
OBS_MODE_NONE = 0
---@type OBS_MODE
OBS_MODE_ROAMING = 6

-- A trace's `mask` field is typed MASK (the same literal union), so widen MASK to integer
-- for assignments like `td.mask = MASK_PLAYERSOLID`.
---@alias MASK integer

-- glua-api-snippets types the default value of CreateConVar as `string`, but the wiki
-- and runtime accept `string|number`.
---@diagnostic disable-next-line: duplicate-set-field
---@param name string
---@param value string|number
---@param flags? FCVAR|FCVAR[]
---@param helptext? string
---@param min? number
---@param max? number
---@return ConVar
function CreateConVar(name, value, flags, helptext, min, max) end
