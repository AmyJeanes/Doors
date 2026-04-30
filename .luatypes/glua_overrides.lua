---@meta

-- glua-api-snippets declares enum aliases (MASK, COLLISION_GROUP, _USE, etc.) as
-- string-literal unions for autocomplete, but the corresponding MASK_*, COLLISION_GROUP_*,
-- *_USE constants are plain integers at runtime. Re-declare the aliases as `integer` so
-- assignments like `Trace.mask = MASK_PLAYERSOLID` type-check.

---@alias MASK integer
---@alias COLLISION_GROUP integer
---@alias _USE integer
---@alias FCVAR integer

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
