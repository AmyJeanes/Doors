-- Sound for interiors and the world around them. See libraries/sound/sh_api.lua for the entry points.

---@class Doors
---@field Sound doors_sound_module

-- Everything the sound modules share. None of it is API - a consumer plays sounds through
-- Doors:PlaySound and never reaches in here.
---@class doors_sound_module
---@field active doors_managed_sound[] every live managed sound, in creation order

Doors.Sound = Doors.Sound or {} ---@type doors_sound_module
Doors.Sound.active = Doors.Sound.active or {}

Doors:LoadFolder("libraries/sound")
