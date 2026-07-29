---@class Doors
---@field Sound doors_sound_module

---@class doors_sound_module
---@field active doors_managed_sound[] every live managed sound, in creation order

Doors.Sound = Doors.Sound or {} ---@type doors_sound_module
Doors.Sound.active = Doors.Sound.active or {}

Doors:LoadFolder("libraries/sound")
