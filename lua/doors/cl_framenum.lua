-- Cheap per-frame token for render-path caches: reading Doors.FrameNum is a table access
-- rather than an engine call to FrameNumber(). Bumped once per frame in PreRender.

---@class Doors
---@field FrameNum integer

Doors.FrameNum = 0
hook.Add("PreRender", "Doors-FrameNum", function()
    Doors.FrameNum = Doors.FrameNum + 1
end)
