-- Cross-boundary audio: a panel for watching and tuning what a doorway does to sound passing through it.
--
-- Open with the console command `doors_debug_sound`. It lives in the context menu, so hold C to adjust
-- and release C to walk - everything keeps updating either way, because it is driven from a Think hook
-- rather than from the panel, and walking is how falloff is actually judged.
--
-- The model itself lives in sh_sound.lua; this only reads the resolution it leaves on each handle, so
-- what the panel shows is exactly what is playing. The tuning sliders write Doors.SoundTuning live and
-- every managed sound picks that up on its next frame, so the numbers can be judged against a real
-- interior hum. The test sound is only there for when nothing else is playing.

---@class doors_sound_debug_sample
---@field name string
---@field path string
---@field space string "interior" or "exterior" - which side to emit it from

---@class doors_sound_debug_cfg
---@field level number SNDLVL of the test sound
---@field volume number caller volume of the test sound
---@field draw3d boolean mark the sound and the doorway in the world
---@field manual boolean hold the door at a chosen openness instead of following the real one
---@field openness number
---@field cross_override boolean drive the consumer's cross-boundary volume from the slider instead of reading it
---@field cross_volume number the cross-boundary volume to force while cross_override is on

---@class doors_sound_debug
---@field cfg doors_sound_debug_cfg
---@field samples doors_sound_debug_sample[]
---@field sel number
---@field rows doors_managed_sound[] list rows, by line id
---@field frame DFrame?
---@field list DListView?
---@field snd doors_managed_sound? the test sound, when one is playing
---@field focus doors_managed_sound? the sound the readouts describe
---@field held gmod_door_exterior? door currently being held open by hand
---@field held_getopenness function? the held door's real GetDoorOpenness, put back exactly on release
---@field cv_held gmod_door_exterior? exterior whose cross-boundary volume is being driven from the slider
---@field cv_getvolume function? that exterior's real GetCrossBoundaryVolume, put back exactly on release
local RIG = {}

-- Autorefresh re-runs this file, which would orphan the old panel inside the context menu and leave its
-- sound playing with nothing driving it.
if Doors.SoundDebug then
    Doors.SoundDebug:Close()
end
Doors.SoundDebug = RIG

RIG.cfg = {
    level          = 75,
    volume         = 1.00,
    draw3d         = true,
    manual         = false,
    openness       = 1.00,
    cross_override = false,
    cross_volume   = 0.50,
}
RIG.rows = {}
RIG.sel = 1

local DBFLOOR = -60 -- bottom of the graph

---@param gain number
---@return number
local function toDb(gain)
    return 20 * math.log10(math.max(gain, 1e-6))
end

-- Convenient test material, not a dependency: two long loops that happen to be to hand and that tuning
-- was done against. Nothing here reads a consumer's content - any other path goes in the box.
RIG.samples = {
    { name = "steady hum, from the interior", path = "p00gie/tardis/default/hum.wav", space = "interior" },
    { name = "steady hum, from the exterior", path = "p00gie/tardis/default/hum.wav", space = "exterior" },
    { name = "busier loop, from the exterior", path = "drmatt/tardis/flight_loop.wav", space = "exterior" },
}

--------------------------------------------------------------------------------------------------
-- Holding a door open
--------------------------------------------------------------------------------------------------

-- The library reads openness through the consumer's own GetDoorOpenness, so hold the door by overriding
-- that on the one entity rather than adding a debug path to the library. Put the real method back exactly
-- on release: nilling the instance override does NOT fall through to the class method on a scripted entity
-- that defines its own (gmod_tardis does), it sticks as nil and every later openness() read then errors.
function RIG:ReleaseDoor()
    local ext = self.held
    if IsValid(ext) then ext.GetDoorOpenness = self.held_getopenness end
    self.held, self.held_getopenness = nil, nil
end

---@param ext gmod_door_exterior?
function RIG:HoldDoor(ext)
    if not self.cfg.manual or not IsValid(ext) then return self:ReleaseDoor() end
    if self.held == ext then return end
    self:ReleaseDoor()
    self.held = ext
    self.held_getopenness = ext.GetDoorOpenness
    function ext:GetDoorOpenness() return RIG.cfg.openness end
end

-- The cross-boundary volume is the consumer's own (GetCrossBoundaryVolume), so preview a value the same
-- way the door is held: override the getter on the focused sound's exterior, saving the real method and
-- putting it back on release. Off by default, so the panel does not touch what you actually hear until
-- you ask it to. This drives every sound crossing that one boundary, which is what makes it audible.
function RIG:ReleaseCrossVolume()
    local ext = self.cv_held
    if IsValid(ext) then ext.GetCrossBoundaryVolume = self.cv_getvolume end
    self.cv_held, self.cv_getvolume = nil, nil
end

---@param ext gmod_door_exterior?
function RIG:HoldCrossVolume(ext)
    if not self.cfg.cross_override or not IsValid(ext) then return self:ReleaseCrossVolume() end
    if self.cv_held == ext then return end
    self:ReleaseCrossVolume()
    self.cv_held = ext
    self.cv_getvolume = ext.GetCrossBoundaryVolume
    function ext:GetCrossBoundaryVolume() return RIG.cfg.cross_volume end
end

--------------------------------------------------------------------------------------------------
-- What is playing
--------------------------------------------------------------------------------------------------

-- The interior to put the test sound in: the one the local player is immediately in, else the nearest.
--
-- `doori` rather than any "am I inside" helper, because interiors nest - a shell parked inside another
-- makes those true for every interior up the chain, so they answer "somewhere within" rather than "which
-- space am I in".
---@return gmod_door_interior?
local function findInterior()
    local ply = LocalPlayer()
    local doori = IsValid(ply) and ply.doori or nil
    if IsValid(doori) and IsValid(doori.exterior) then return doori end
    local best, bestd
    for int in pairs(Doors:GetInteriors()) do
        if IsValid(int) and IsValid(int.exterior) then
            local d = EyePos():DistToSqr(int.exterior:GetPos())
            if not bestd or d < bestd then best, bestd = int, d end
        end
    end
    return best
end

function RIG:Stop()
    local snd = self.snd
    if snd ~= nil and not snd.stopped then snd:Stop() end
    if self.focus == snd then self.focus = nil end
    self.snd = nil
end

function RIG:Play()
    self:Stop()
    local sample = self.samples[self.sel]
    local int = findInterior()
    if not (sample and IsValid(int)) then return end
    ---@cast int gmod_door_interior
    local ent = sample.space == "interior" and int or int.exterior
    if not IsValid(ent) then return end
    -- from the middle of the space rather than the entity origin, which on a resizable interior can sit
    -- out at one wall
    self.snd = Doors:PlaySound({
        path = sample.path, ent = ent, offset = ent:OBBCenter(), loop = true,
        volume = self.cfg.volume, level = self.cfg.level,
    })
    self.focus = self.snd
end

---@return boolean
function RIG:CanPlay()
    return IsValid(findInterior())
end

---@param h doors_managed_sound
---@return string
local function describe(h)
    local ent = h.ent
    if IsValid(ent) then return ent:GetClass() end
    return h.pos and "fixed point" or "no position"
end

-- Rows follow Doors.ActiveManagedSounds, rebuilt only when that set changes so a selection survives.
function RIG:RefreshList()
    local list = self.list
    if not IsValid(list) then return end
    ---@cast list DListView
    local active = Doors.ActiveManagedSounds
    local stale = #active ~= #self.rows
    if not stale then
        for k, h in ipairs(active) do
            if self.rows[k] ~= h then stale = true break end
        end
    end

    if stale then
        list:Clear()
        local rows = {} ---@type doors_managed_sound[]
        self.rows = rows
        for k, h in ipairs(active) do
            rows[k] = h
            local name = string.GetFileFromFilename(h.path) or h.path
            local line = list:AddLine(h == self.snd and (name .. "  (test)") or name, describe(h), "")
            if h == self.focus then list:SelectItem(line) end
        end
    end

    for k, h in ipairs(self.rows) do
        local line = list:GetLine(k)
        if IsValid(line) then
            line:SetColumnText(2, h.patch and "engine" or (h.res.int and "through a doorway" or describe(h)))
            line:SetColumnText(3, h.patch and "-"
                or (h.parked and "parked" or string.format("%.1f dB", toDb(h.volume))))
        end
    end
end

local function think()
    local ok, err = pcall(function()
        local focus = RIG.focus
        -- a sound that finished is dropped from the active list without being stopped
        if focus and not table.HasValue(Doors.ActiveManagedSounds, focus) then
            if focus == RIG.snd then RIG.snd = nil end
            RIG.focus = nil
            focus = nil
        end
        local int = focus and focus.res.int or findInterior()
        RIG:HoldDoor(IsValid(int) and int.exterior or nil)
        RIG:HoldCrossVolume(IsValid(int) and int.exterior or nil)

        -- the two sliders that are ours to move, pushed at the handle rather than only read when it
        -- starts, so they can be judged while it plays
        local snd = RIG.snd
        if snd ~= nil and not snd.stopped then
            snd.base, snd.level = RIG.cfg.volume, RIG.cfg.level
        end
    end)
    if not ok then
        RIG:Close()
        ErrorNoHalt("cross-boundary sound debug stopped: " .. tostring(err) .. "\n")
    end
end

--------------------------------------------------------------------------------------------------
-- World markers
--------------------------------------------------------------------------------------------------

---@param face doors_sound_face
---@param col table
local function drawMouth(face, col)
    local portal = face.portal
    local centre = face.ent:LocalToWorld(portal.pos)
    local ang = face.ent:LocalToWorldAngles(portal.ang)
    local r, u = ang:Right() * (portal.width / 2), ang:Up() * (portal.height / 2)
    local c = { centre - r - u, centre + r - u, centre + r + u, centre - r + u }
    for k = 1, 4 do
        render.DrawLine(c[k], c[k % 4 + 1], col, false)
    end
end

---@param _ boolean
---@param skybox boolean
local function draw3d(_, skybox)
    if skybox or not RIG.cfg.draw3d then return end
    pcall(function()
        local h = RIG.focus
        if h == nil then return end
        local res = h.res
        local emitter = res.emitter
        if emitter == nil then return end
        render.SetColorMaterial()

        local listener = res.listener
        if listener then
            drawMouth(listener, Color(90, 200, 120))
            local c = listener.ent:LocalToWorld(listener.portal.pos)
            render.DrawLine(c, c + (res.normal or vector_origin) * 48, Color(90, 200, 120, 200), false)
        end
        if res.source and res.source ~= listener then
            drawMouth(res.source, Color(70, 120, 190))
        end

        -- Where the sound actually is - the emitter, not the doorway the model resolves it to, which
        -- across a boundary is a different room entirely. This runs inside portal passes too, so from
        -- outside it shows through the doorway, sitting where the sound really is.
        local loud = math.Clamp((toDb(h.volume) - DBFLOOR) / -DBFLOOR, 0, 1)
        render.DrawWireframeSphere(emitter, 12 + loud * 30, 12, 12,
            Color(255, 200 - loud * 140, 60, 255), false)
        render.DrawLine(emitter, emitter - Vector(0, 0, 96), Color(255, 200, 60, 120), false)

        -- and, small, where it is heard from once through the doorway - what carries the direction
        if res.pos and res.pos ~= emitter then
            render.DrawWireframeSphere(res.pos, 7, 6, 6, Color(120, 190, 240, 200), false)
        end

        -- The label rides in the world rather than on the HUD so it travels with the marker through a
        -- doorway; a screen projection is computed against the main view, so it would vanish exactly
        -- when the sound it belongs to is only visible through one.
        local face = Angle(0, EyeAngles().y - 90, 90)
        cam.Start3D2D(emitter + Vector(0, 0, 64), face,
            math.Clamp(EyePos():Distance(emitter) / 3000, 0.06, 0.6))
            draw.SimpleText(string.format("%.1f dB", toDb(h.volume)), "DermaLarge", 0, 0,
                Color(255, 220, 120), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.SimpleText(string.format("%.0fu along the path", res.dist), "DermaDefaultBold", 0, 26,
                Color(220, 220, 230), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        cam.End3D2D()
    end)
end

--------------------------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------------------------

function RIG:Close()
    self:Stop()
    self:ReleaseDoor()
    self:ReleaseCrossVolume()
    self.focus = nil
    hook.Remove("Think", "doors_debug_sound")
    hook.Remove("PostDrawTranslucentRenderables", "doors_debug_sound")
    if IsValid(self.frame) then self.frame:Remove() end
    self.frame = nil
    self.list = nil
end

-- Lives in the context menu rather than as a popup, so holding C adjusts and releasing C walks.
---@param reveal boolean? pop the context menu open rather than leaving it as it was
function RIG:Open(reveal)
    local cmenu = g_ContextMenu --[[@as ContextMenuPanel]]
    if IsValid(self.frame) then
        if reveal and IsValid(cmenu) and not cmenu:IsVisible() then cmenu:Open() end
        self.frame:SetVisible(true)
        return
    end
    local cfg = self.cfg
    local tuning = Doors.SoundTuning
    local culling = Doors.SoundCulling

    local f = (IsValid(cmenu) and cmenu:Add("DFrame") or vgui.Create("DFrame")) --[[@as DFrame]]
    self.frame = f
    f:SetSize(470, 780)
    f:SetPos(40, 40)
    f:SetTitle("Cross-boundary audio")
    f:SetSizable(true)
    if IsValid(cmenu) then
        -- A panel born while the context menu is shut inherits its disabled input and never gets it
        -- back, so it draws normally and ignores every click. Set it before building the children, so
        -- each one still inherits its own natural default - a label is meant to be mouse-transparent.
        f:SetMouseInputEnabled(true)
        f:SetKeyboardInputEnabled(true)
        if reveal and not cmenu:IsVisible() then cmenu:Open() end
    else
        f:MakePopup()
    end
    function f:OnClose() RIG:Close() end

    hook.Add("Think", "doors_debug_sound", think)
    hook.Add("PostDrawTranslucentRenderables", "doors_debug_sound", draw3d)

    local scroll = vgui.Create("DScrollPanel", f)
    scroll:Dock(FILL)

    ---@param text string
    local function label(text)
        local l = scroll:Add("DLabel")
        l:Dock(TOP) l:DockMargin(6, 8, 6, 0)
        l:SetText(text) l:SetTextColor(Color(220, 220, 235)) l:SetFont("DermaDefaultBold")
    end

    local widgets = {} ---@type table[] tracked so Reset can push restored values back into them
    ---@param text string
    ---@param min number
    ---@param max number
    ---@param dec number
    ---@param store table
    ---@param key string
    ---@param enabled? fun(): boolean when given, greys the slider out while it returns false
    local function slider(text, min, max, dec, store, key, enabled)
        local sl = scroll:Add("DNumSlider")
        sl:Dock(TOP) sl:DockMargin(6, 2, 6, 0)
        sl:SetText(text) sl:SetMinMax(min, max) sl:SetDecimals(dec) sl:SetValue(store[key])
        ---@param v number
        function sl:OnValueChanged(v) store[key] = v end
        if enabled then
            function sl:Think() self:SetEnabled(enabled() and true or false) end
        end
        if store == tuning or store == culling then widgets[#widgets + 1] = { sl, store, key } end
    end
    ---@param text string
    ---@param key string
    local function check(text, key)
        local c = scroll:Add("DCheckBoxLabel")
        c:Dock(TOP) c:DockMargin(6, 6, 6, 0)
        c:SetText(text) c:SetValue(cfg[key])
        ---@param v boolean
        function c:OnChange(v) cfg[key] = v end
    end
    ---@param text string
    ---@param fn function
    ---@param enabled? fun(): boolean when given, greys the button out while it returns false
    local function button(text, fn, enabled)
        local b = scroll:Add("DButton")
        b:Dock(TOP) b:DockMargin(6, 4, 6, 0) b:SetTall(26) b:SetText(text)
        function b:DoClick() fn() end
        if enabled then
            function b:Think() self:SetEnabled(enabled() and true or false) end
        end
    end

    label("Sounds playing - pick one to describe below")
    local list = scroll:Add("DListView")
    self.list = list
    list:Dock(TOP) list:DockMargin(6, 2, 6, 0) list:SetTall(120) list:SetMultiSelect(false)
    list:AddColumn("sound")
    list:AddColumn("where from"):SetFixedWidth(130)
    list:AddColumn("level"):SetFixedWidth(60)
    ---@param id number
    function list:OnRowSelected(id) RIG.focus = RIG.rows[id] end
    function list:Think() RIG:RefreshList() end

    label("A test sound, for when nothing else is playing")
    local combo = scroll:Add("DComboBox")
    combo:Dock(TOP) combo:DockMargin(6, 2, 6, 0)
    for k, e in ipairs(self.samples) do combo:AddChoice(e.name, k, k == self.sel) end
    ---@param _ number
    ---@param _b string
    ---@param data number
    function combo:OnSelect(_, _b, data) RIG.sel = data RIG:Play() end

    -- so a consumer's own asset can be tuned against without this module knowing any of them
    local path = scroll:Add("DTextEntry")
    path:Dock(TOP) path:DockMargin(6, 4, 6, 0)
    path:SetPlaceholderText("...or type a sound path and press enter")
    ---@param value string
    function path:OnEnter(value)
        if value == "" then return end
        RIG.samples[#RIG.samples + 1] =
            { name = value, path = value, space = RIG.samples[RIG.sel].space }
        RIG.sel = #RIG.samples
        combo:AddChoice(value, RIG.sel, true)
        RIG:Play()
    end

    button("PLAY", function() RIG:Play() end, function() return RIG:CanPlay() end)
    button("Stop", function() RIG:Stop() end, function() return RIG.snd ~= nil end)

    -- Only the test sound's own level is ours to move; every other handle's belongs to whatever started
    -- it, and writing to that would be tuning the caller rather than the doorway.
    local function testFocused() return RIG.focus ~= nil and RIG.focus == RIG.snd end
    slider("SNDLVL of the test sound", 40, 120, 0, cfg, "level", testFocused)
    slider("volume of the test sound", 0, 1, 2, cfg, "volume", testFocused)

    -- The A/B. Everything below stops meaning anything while this is on, because none of it is ours to
    -- compute any more - which is the comparison.
    label("Compare against the engine")
    local engine = scroll:Add("DCheckBoxLabel")
    engine:Dock(TOP) engine:DockMargin(6, 6, 6, 0)
    engine:SetText("play everything the way Source would, with no library in the way")
    engine:SetConVar("doors_sound_engine")

    label("Aperture - a flat gain, 1 when the door is fully open")
    slider("closed coefficient", 0, 1, 3, tuning, "closed")
    slider("openness curve exponent", 0.25, 5, 2, tuning, "curve")

    label("What the doorway costs a sound coming through it")
    slider("dB per 1000u, per halving of the doorway", 0, 40, 2, tuning, "falloff")
    slider("how much it aims its sound (0 = every way)", 0, 1, 2, tuning, "aim")

    label("Cross-boundary volume - the consumer's own, previewed here")
    check("drive it from the slider (off = use the real value)", "cross_override")
    slider("carries this much 1000u past the mouth", 0, 1, 2, cfg, "cross_volume",
        function() return cfg.cross_override end)

    label("Virtualising distant sounds - free the channel, keep the handle")
    slider("park below (dB)", -72, -30, 0, culling, "park_db")
    slider("wake above (dB)", -72, -30, 0, culling, "unpark_db")
    slider("wait this long below the floor first (s)", 0, 10, 1, culling, "delay")

    label("Door")
    check("hold the door at a set openness", "manual")
    slider("openness", 0, 1, 3, cfg, "openness", function() return cfg.manual end)
    check("mark the sound and doorway in the world", "draw3d")

    -- Two absolute numbers rather than a ratio: a ratio drifts as you walk for reasons that have nothing
    -- to do with the doorway. Left, how loud it is where you stand; right, what the doorway costs, which
    -- holds still while you move because it depends only on the tuning.
    local summary = scroll:Add("DPanel")
    summary:Dock(TOP) summary:DockMargin(6, 10, 6, 0) summary:SetTall(62)
    ---@param w number
    ---@param h number
    function summary:Paint(w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(26, 28, 34))
        local snd = RIG.focus
        if snd == nil then
            draw.SimpleText("pick a sound above", "DermaDefault", w / 2, h / 2, Color(150, 90, 90),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            return
        end
        if snd.patch then
            draw.SimpleText("played by the engine - nothing here is ours to measure", "DermaDefault",
                w / 2, h / 2, Color(150, 140, 90), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            return
        end
        local res = snd.res
        local half = w / 2
        draw.SimpleText("you hear", "DermaDefault", half / 2, 13, Color(150, 155, 170),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        -- parked = the channel is freed, so nothing is playing and snd.volume is frozen at the park
        -- point; say so rather than showing that stale dB as if it were still being heard
        draw.SimpleText(snd.parked and "parked" or string.format("%.1f dB", toDb(snd.volume)),
            "DermaLarge", half / 2, 34, snd.parked and Color(150, 160, 180) or Color(200, 215, 235),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(string.format("%.0fu from the sound", res.dist), "DermaDefault", half / 2, 52,
            Color(130, 135, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        surface.SetDrawColor(60, 64, 76)
        surface.DrawRect(half, 8, 1, h - 16)
        if res.int == nil then
            draw.SimpleText("no doorway in the path", "DermaDefault", half + half / 2, h / 2,
                Color(130, 135, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            return
        end
        -- res.gain, not res.aperture: the whole doorway cost (aperture, size falloff, directivity and the
        -- cross-boundary volume together), so this matches what the doorway actually takes off a sound at
        -- your position rather than only the door-openness part, which reads 0 the moment the door is open.
        draw.SimpleText("the doorway costs", "DermaDefault", half + half / 2, 13,
            Color(150, 155, 170), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(string.format("%.1f dB", toDb(res.gain)), "DermaLarge", half + half / 2, 34,
            Color(110, 210, 130), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(string.format("door %.0f%% open", res.openness * 100), "DermaDefault",
            half + half / 2, 52, Color(130, 135, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- Level against distance FROM THE SOUND, along the path it travels, so walking in any direction
    -- moves the marker the way you would expect. One continuous curve: plain falloff up to the doorway,
    -- then the through-the-doorway falloff past it. The step down at the doorway line is the aperture
    -- and the widening gap to the faint line is the extra falloff, so both are visible at once. dB up
    -- the side, because linear gain squashes everything interesting into the bottom pixel.
    local plot = scroll:Add("DPanel")
    plot:Dock(TOP) plot:DockMargin(6, 6, 6, 0) plot:SetTall(180)
    ---@param w number
    ---@param h number
    function plot:Paint(w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(26, 28, 34))
        local snd = RIG.focus
        if snd == nil or snd.patch then return end
        local res = snd.res
        local lvl = snd.level or 75
        local pad = 30
        local maxd = math.max(1200, res.dist * 1.3)
        local pw, ph = w - pad - 10, h - 34
        surface.SetDrawColor(38, 41, 50)
        surface.DrawRect(pad, 10, pw, ph)

        ---@param gain number
        ---@return number
        local function ypos(gain)
            return 10 + ph * math.Clamp(toDb(gain) / DBFLOOR, 0, 1)
        end
        for db = -12, DBFLOOR, -12 do
            local y = 10 + ph * (db / DBFLOOR)
            surface.SetDrawColor(52, 56, 66)
            surface.DrawRect(pad, y, pw, 1)
            draw.SimpleText(db .. "", "DermaDefault", pad - 4, y, Color(110, 115, 130),
                TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
        end

        ---@param from number
        ---@param to number
        ---@param fn fun(d: number): number
        ---@param col table
        local function curve(from, to, fn, col)
            surface.SetDrawColor(col)
            local px, py
            for s = 0, 60 do
                local d = from + (to - from) * s / 60
                local x = pad + pw * math.Clamp(d / maxd, 0, 1)
                local y = ypos(fn(d))
                if px then surface.DrawLine(px, py, x, y) end
                px, py = x, y
            end
        end

        curve(1, res.int and res.d1 or maxd, function(d)
            return Doors:DistanceGain(d, lvl)
        end, Color(110, 150, 220))
        if res.int then
            curve(res.d1, maxd, function(d) return Doors:DistanceGain(d, lvl) end, Color(70, 85, 120))
            curve(res.d1, maxd, function(d)
                -- Directivity (an angle term) and the cross-boundary volume (a falloff) both reach 1 at
                -- the mouth in the model, so reproduce that: ramp directivity from 1 to the listener's
                -- value, and raise volume by distance past the mouth. The curve then meets the in-room line
                -- at an open door, while the marker (res.applied) still lands on it at your distance.
                local t = res.d2 > 0 and math.Clamp((d - res.d1) / res.d2, 0, 1) or 1
                local directivity = 1 + (res.directivity - 1) * t
                local volExtra = res.volume > 0 and res.volume ^ ((d - res.d1) / 1000) or 0
                return Doors:DistanceGain(d, lvl) * res.aperture * directivity * volExtra
                    * 10 ^ (-(res.db_per_1000 * (d - res.d1) / 1000) / 20)
            end, Color(110, 210, 130))

            local dx = pad + pw * math.Clamp(res.d1 / maxd, 0, 1)
            surface.SetDrawColor(230, 190, 80, 120)
            surface.DrawRect(dx - 1, 10, 2, ph)
            draw.SimpleText("doorway", "DermaDefault", dx + 4, 12, Color(230, 190, 80))
        end

        local mx = pad + pw * math.Clamp(res.dist / maxd, 0, 1)
        surface.SetDrawColor(255, 255, 255, 200)
        surface.DrawRect(mx - 1, 10, 2, ph)
        surface.SetDrawColor(255, 255, 255)
        surface.DrawRect(mx - 3, ypos(res.applied) - 3, 6, 6)

        -- the cull floors, dashed across the graph, so the headroom before this sound parks is visible
        local cull = Doors.SoundCulling
        ---@param db number
        ---@param text string
        ---@param col table
        local function floorLine(db, text, col)
            local y = 10 + ph * math.Clamp(db / DBFLOOR, 0, 1)
            surface.SetDrawColor(col)
            for x = pad, pad + pw - 4, 8 do surface.DrawRect(x, y, 4, 1) end
            draw.SimpleText(text, "DermaDefault", pad + pw - 2, y - 8, col, TEXT_ALIGN_RIGHT)
        end
        floorLine(cull.park_db, "park", Color(210, 120, 90))
        floorLine(cull.unpark_db, "wake", Color(120, 170, 210))

        draw.SimpleText("in the room", "DermaDefault", pad + 2, h - 18, Color(110, 150, 220))
        draw.SimpleText("through the doorway", "DermaDefault", pad + 84, h - 18, Color(110, 210, 130))
        draw.SimpleText("no doorway", "DermaDefault", pad + 220, h - 18, Color(70, 85, 120))
        draw.SimpleText(string.format("%.0fu", maxd), "DermaDefault", w - 10, h - 18,
            Color(150, 155, 170), TEXT_ALIGN_RIGHT)
    end

    label("Live")
    local readout = scroll:Add("DLabel")
    readout:Dock(TOP) readout:DockMargin(6, 4, 6, 12)
    readout:SetTall(170) readout:SetContentAlignment(7)
    readout:SetTextColor(Color(185, 220, 195))
    function readout:Think() self:SetText(RIG:Stats()) end

    button("DUMP THESE VALUES", function()
        local t, c = Doors.SoundTuning, Doors.SoundCulling
        MsgN(string.format([[

-- tuned in doors_debug_sound
closed    = %.3f,   -- fully open is 1 by construction
curve     = %.2f,
falloff   = %.2f,   -- dB per 1000u per halving below SIZE_NEUTRAL
aim       = %.2f,
park_db   = %.0f,   -- free a channel that has sat below this
unpark_db = %.0f,   -- reload once it climbs back above this
delay     = %.0f,   -- seconds below the floor before parking
]], t.closed, t.curve, t.falloff, t.aim, c.park_db, c.unpark_db, c.delay))
        chat.AddText("dumped to console")
    end)

    button("RESET TO DEFAULTS", function()
        for k, v in pairs(Doors.SoundTuningDefaults) do tuning[k] = v end
        for k, v in pairs(Doors.SoundCullingDefaults) do culling[k] = v end
        for _, entry in ipairs(widgets) do
            local pnl, store, key = entry[1], entry[2], entry[3]
            if IsValid(pnl) then pnl:SetValue(store[key]) end
        end
    end)
end

---@return string
function RIG:Stats()
    local out = {}
    ---@param k string
    ---@param v string
    local function line(k, v) out[#out + 1] = string.format("%-9s %s", k, v) end
    local snd = self.focus
    if snd == nil then
        line("STATE", #Doors.ActiveManagedSounds == 0
            and "nothing playing - press PLAY for a test sound"
            or "pick a sound from the list")
        return table.concat(out, "\n")
    end
    if snd.patch then
        line("SOUND", snd.path)
        line("ENGINE", string.format("played by Source at volume %.3f - distance, pan and looping are "
            .. "all its own, so nothing below applies", snd.base))
        return table.concat(out, "\n")
    end
    local res = snd.res
    line("SOUND", string.format("%s   base %.3f -> playing %.4f%s", snd.path, snd.base, snd.volume,
        snd.omni and "   stereo wav, so omni and unpanned" or ""))
    line("CULLING", snd.parked and "parked - channel freed, handle kept until it is heard again"
        or string.format("live, %.1f dB (parks below %.0f dB after %ds)", toDb(res.applied),
            Doors.SoundCulling.park_db, Doors.SoundCulling.delay))
    line("SETTLING", res.healing > 0
        and string.format("%.0f%% of a space change left, gliding from %.1f dB", res.healing * 100,
            toDb(snd.heal_from or 1))
        or "settled")
    if res.int == nil then
        line("PATH", string.format("%.0fu, no doorway between you and it", res.dist))
        return table.concat(out, "\n")
    end
    line("LISTENER", res.inside and "inside, and the sound is not" or "outside, and the sound is in")
    line("PATH", string.format("sound %.0fu -> doorway, doorway %.0fu -> you  (total %.0fu)",
        res.d1, res.d2, res.dist))
    line("BASELINE", string.format("%.1f dB   free field over the whole path",
        toDb(Doors:DistanceGain(res.dist, snd.level or 75))))
    line("APERTURE", string.format("%.1f dB   at %.0f%% open", toDb(res.aperture), res.openness * 100))
    line("FALLOFF", string.format("%.1f dB here   (%.2f dB/1000u from a %.0f square unit doorway)",
        toDb(res.extra), res.db_per_1000, res.area))
    line("AIM", string.format("%.1f dB   facing %+.2f (%s)", toDb(res.directivity), res.facing,
        res.facing > 0.3 and "in front of it" or (res.facing < -0.3 and "round the back" or "edge on")))
    line("CROSS-VOL", string.format("%.1f dB here   %.0f%% carries 1000u past the mouth",
        toDb(res.vol_extra), res.volume * 100))
    line("DOORWAY", string.format("%.1f dB in total", toDb(res.gain)))
    return table.concat(out, "\n")
end

concommand.Add("doors_debug_sound", function() RIG:Open(true) end)
