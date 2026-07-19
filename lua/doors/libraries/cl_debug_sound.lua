-- Cross-boundary audio: a tuning panel for how a doorway affects sound passing through it.
--
-- Open with the console command `doors_debug_sound`. It lives in the context menu, so hold C to
-- adjust and release C to walk - the sound keeps resolving either way, because it is driven from a
-- Think hook rather than from the panel, and walking is how falloff is actually judged.
--
-- It prototypes rather than mocks: it plays a real Doors:PlaySound handle and then owns that handle's
-- position and volume each frame, clearing its level so the library does not also apply its own. So
-- the model below computes the whole distance chain, while pan, occlusion, the mixer constant and the
-- master volume stay the shipping path underneath.
--
-- The model. A doorway is two effects on top of an ordinary sound, never a replacement for one. The
-- baseline is the plain engine falloff over the *whole* path the sound travels - out to the doorway
-- and on to the listener - and the doorway then takes away:
--
--   1. aperture     a flat gain, exactly 1 when fully open, below 1 as the door shuts, never 0
--   2. extra falloff dB per 1000u, for each halving of the doorway below the size at which it stops
--                    mattering; exactly 0 at the doorway itself and 0 for a large enough opening
--   3. directivity   a doorway throws its sound outward, so behind it you hear only what bends round
--
-- All three vanish at the doorway with it open, which is the invariant the whole thing rests on:
-- standing in an open doorway is identical to standing in the room, not merely close to it.

---@class doors_sound_debug_side
---@field ent Entity the interior or exterior the doorway belongs to
---@field portal doors_portal_side

---@class doors_sound_debug_sample
---@field name string
---@field path string
---@field space string "interior" or "exterior" - which side it is emitted from

---@class doors_sound_debug_cfg
---@field closed number aperture when fully shut; open is 1 by definition and is not a setting
---@field curve number exponent on openness, so a door barely cracked does not jump to full
---@field falloff number dB per 1000u, per halving of the doorway below SIZE_NEUTRAL
---@field aim number 0 radiates every way equally, 1 silent directly behind
---@field size_override number pretend the doorway is this many square units; 0 uses the real one
---@field level number the sound's own SNDLVL
---@field volume number
---@field draw3d boolean mark the sound and the doorway in the world
---@field manual boolean drive openness from the slider instead of the real door
---@field openness number

---@class doors_sound_debug_info
---@field ok boolean
---@field why string?
---@field int gmod_door_interior?
---@field inside boolean
---@field sameSpace boolean
---@field openness number
---@field aperture number
---@field area number
---@field realArea number
---@field d1 number emitter to its own doorway
---@field d2 number listener's doorway to the listener
---@field halvings number
---@field dbPer1000 number
---@field extra number
---@field facing number
---@field directivity number
---@field direct number gain if the listener shares the emitter's space
---@field folded number free field over the whole path
---@field cross number gain through the doorway
---@field gain number what is actually playing
---@field healing number 0-1 of a captured space-change step still to fade
---@field path number distance from the sound along the path it travels
---@field pos Vector where the sound is played from
---@field emitterPos Vector where the sound actually is
---@field listenerMouth Vector nearest point on the listener's doorway
---@field listenerSide doors_sound_debug_side?
---@field sourceSide doors_sound_debug_side?

---@class doors_sound_debug
---@field cfg doors_sound_debug_cfg
---@field defaults doors_sound_debug_cfg
---@field info doors_sound_debug_info
---@field samples doors_sound_debug_sample[]
---@field sel number
---@field frame DFrame?
---@field snd doors_managed_sound?
---@field openness number? rate-limited, so it cannot cross faster than the transition floor
---@field heal_db number
---@field heal_left number
---@field was_sameSpace boolean?
---@field last_target number?
local RIG = {}

-- Autorefresh re-runs this file, which would orphan the old panel inside the context menu and leave
-- its sound playing with nothing driving it.
if Doors.SoundDebug then
    if IsValid(Doors.SoundDebug.frame) then Doors.SoundDebug.frame:Remove() end
    if IsValid(Doors.SoundDebug.snd) then Doors.SoundDebug.snd:Stop() end
end
Doors.SoundDebug = RIG

RIG.cfg = {
    closed        = 0.12,
    curve         = 2.00,
    falloff       = 3.00,
    aim           = 0.70,
    size_override = 0,
    level         = 75,
    volume        = 1.00,
    draw3d        = true,
    manual        = false,
    openness      = 1.00,
}
RIG.defaults = table.Copy(RIG.cfg)
-- built through a typed return rather than annotated as a literal, which would be checked against
-- every field of the class before a single resolve has filled them in
---@return doors_sound_debug_info
local function newInfo() return { ok = false } end
RIG.info = newInfo()
RIG.heal_db, RIG.heal_left = 0, 0
RIG.sel = 1

-- The doorway area at and above which size stops mattering - an opening this big is acoustically just
-- a gap in the wall. Roughly 128x128, a plain physical size rather than anything drawn from one
-- consumer's content, since doorways range from a cupboard to thousands of units a side.
--
-- This is the falloff setting's other half and deliberately not a second slider: strength * halvings
-- expands to strength * (log2(NEUTRAL) - log2(area)), so moving it shifts every doorway together
-- while the slider changes how much size separates them. Having both adjustable made neither
-- readable. It is pinned by a physical question instead, so it can be answered once and left alone.
local SIZE_NEUTRAL = 16384

-- The floor on any transition. Long enough that a listener changing space does not click, short
-- enough that it is over before a teleport has finished resolving on screen.
local TRANSITION_FLOOR = 0.5

local DBFLOOR = -60 -- bottom of the graph

---@param gain number
---@return number
local function toDb(gain)
    return 20 * math.log10(math.max(gain, 1e-6))
end

--------------------------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------------------------

-- Where a sound sits when it is "in the room": the middle of the space, not the entity origin, which
-- for a resizable interior can be off at one wall.
---@param ent Entity
---@return Vector
local function middleOf(ent)
    local c = ent:OBBCenter()
    if c:IsZero() then return ent:GetPos() end
    return ent:LocalToWorld(c)
end

-- Which way a doorway faces: its authored forward, which already points into the space you stand in
-- to use it - out into the world for an exterior, into the room for an interior.
--
-- Deriving the sign instead, by pointing it away from the middle of the entity the doorway sits in,
-- looks more robust and is worse. A free-standing doorframe has its opening essentially at its own
-- centre, so there is no "away" to find and the test lands on a rounding error; and on an interior it
-- gets the answer backwards, pointing out through the wall. The author already said which way it faces.
---@param side doors_sound_debug_side
---@return Vector
local function mouthNormal(side)
    return side.ent:LocalToWorldAngles(side.portal.ang):Forward()
end

-- The nearest point on a doorway to `p`, rather than its centre.
--
-- Treating a doorway as a point is only harmless while it is small - at a 50x92 door the worst case is
-- about 50 units. Doorways reach thousands of units a side, where standing in the corner of the
-- opening is thousands from its centre, so a centre-based distance would call you far away while you
-- are stood in it. Clamping into the rectangle costs nothing and holds at any size.
---@param side doors_sound_debug_side
---@param p Vector
---@return Vector
local function mouthPoint(side, p)
    local portal = side.portal
    local centre = side.ent:LocalToWorld(portal.pos)
    local ang = side.ent:LocalToWorldAngles(portal.ang)
    local right, up = ang:Right(), ang:Up()
    local d = p - centre
    return centre
        + right * math.Clamp(d:Dot(right), -portal.width / 2, portal.width / 2)
        + up * math.Clamp(d:Dot(up), -portal.height / 2, portal.height / 2)
end

---@param side doors_sound_debug_side
---@return Vector[]
local function mouthCorners(side)
    local portal = side.portal
    local centre = side.ent:LocalToWorld(portal.pos)
    local ang = side.ent:LocalToWorldAngles(portal.ang)
    local r, u = ang:Right() * (portal.width / 2), ang:Up() * (portal.height / 2)
    return { centre - r - u, centre + r - u, centre + r + u, centre - r + u }
end

-- Both sides of the boundary, and the area of the tighter of the two.
---@param int gmod_door_interior
---@return doors_sound_debug_side? interior
---@return doors_sound_debug_side? exterior
---@return number area
local function sides(int)
    local ext = int.exterior
    if not IsValid(ext) then return nil, nil, 0 end
    local ip, ep = int:GetDoorway(), ext:GetDoorway()
    if not ip or not ep then return nil, nil, 0 end
    return { ent = int, portal = ip }, { ent = ext, portal = ep },
        math.min(ip.width * ip.height, ep.width * ep.height)
end

-- The interior under test: the one the local player is immediately in, else the nearest.
--
-- `doori` rather than any "am I inside" helper, because interiors nest - a shell parked inside another
-- makes those true for every interior up the chain, so they answer "somewhere within" rather than
-- "which space am I in". Resolving a boundary needs the immediate one.
---@return gmod_door_interior?
local function findInterior()
    local ply = LocalPlayer()
    local doori = IsValid(ply) and ply.doori or nil
    if IsValid(doori) and IsValid(doori.exterior) then return doori end
    local best, bestd
    for _, ent in ipairs(ents.GetAll()) do
        if ent.DoorInterior and IsValid(ent.exterior) then
            local d = EyePos():DistToSqr(ent.exterior:GetPos())
            if not bestd or d < bestd then best, bestd = ent, d end
        end
    end
    return best
end

--------------------------------------------------------------------------------------------------
-- The model
--------------------------------------------------------------------------------------------------

-- Convenient test material, not a dependency: these are just two long loops that happen to be to hand
-- and that tuning was done against. Nothing here reads a consumer's content - any other path can be
-- typed into the box on the panel.
RIG.samples = {
    { name = "steady hum, from the interior", path = "p00gie/tardis/default/hum.wav", space = "interior" },
    { name = "steady hum, from the exterior", path = "p00gie/tardis/default/hum.wav", space = "exterior" },
    { name = "busier loop, from the exterior", path = "drmatt/tardis/flight_loop.wav", space = "exterior" },
}

---@param int gmod_door_interior
---@return number
function RIG:Openness(int)
    if self.cfg.manual then return self.cfg.openness end
    local ext = int.exterior
    if IsValid(ext) then return math.Clamp(ext:GetDoorOpenness(), 0, 1) end
    return 1
end

---@return doors_sound_debug_info
function RIG:Resolve()
    local cfg = self.cfg
    local i = self.info
    i.ok = false

    local int = findInterior()
    if not IsValid(int) then i.why = "no interior found" return i end
    ---@cast int gmod_door_interior
    local sample = self.samples[self.sel]
    if not sample then i.why = "no sound selected" return i end

    local intSide, extSide, area = sides(int)
    if not (intSide and extSide) then i.why = "no doorway on this interior" return i end

    local ply = LocalPlayer()
    local inside = IsValid(ply) and ply.doori == int or false

    local emitterEnt = sample.space == "interior" and int or int.exterior
    local emitterPos = IsValid(emitterEnt) and middleOf(emitterEnt) or EyePos()
    local sameSpace = (sample.space == "interior") == inside

    -- Which doorway is which follows from whose side it is on, never from where the listener is: the
    -- emitter always radiates into the one on its own side. Keying either off the listener makes the
    -- source leg measure across the void the moment both are in the same space.
    local sourceSide = sample.space == "interior" and intSide or extSide
    local listenerSide = inside and intSide or extSide
    local sourceMouth = mouthPoint(sourceSide, emitterPos)
    local listenerMouth = mouthPoint(listenerSide, EyePos())

    -- Rate-limit openness rather than everything derived from it, so one floor covers a door
    -- animating, a door with no animation at all, and a value yanked by hand.
    local raw = self:Openness(int)
    self.openness = math.Approach(self.openness or raw, raw, FrameTime() / TRANSITION_FLOOR)
    local openness = self.openness

    local aperture = cfg.closed + (1 - cfg.closed) * openness ^ cfg.curve

    local d1 = emitterPos:Distance(sourceMouth)
    local d2 = EyePos():Distance(listenerMouth)

    local realArea = area
    if cfg.size_override > 0 then area = cfg.size_override end
    -- How many times the doorway would have to double to stop being small. Log-scaled because areas
    -- span orders of magnitude across consumers, and clamped at zero so a large opening is merely
    -- unpenalised rather than credited - this term must never be able to make anything louder.
    local halvings = math.max(0, math.log(SIZE_NEUTRAL / math.max(area, 1), 2))
    local dbPer1000 = cfg.falloff * halvings
    local extra = 10 ^ (-(dbPer1000 * d2 / 1000) / 20)

    -- Linear in the cosine, which is gentle - a hum is low-frequency, and low frequencies are the
    -- least directional thing there is. At the doorway itself the direction is meaningless, so 1.
    local facing = 1
    if d2 > 1 then
        facing = mouthNormal(listenerSide):Dot((EyePos() - listenerMouth):GetNormalized())
    end
    local directivity = 1 - cfg.aim * 0.5 * (1 - facing)

    local direct = Doors:DistanceGain(EyePos():Distance(emitterPos), cfg.level)
    -- Attenuating each leg of the path separately instead - the obvious two-stage reading - is wrong
    -- against Source's curve, which compresses gain above 0.5: two short legs both sit in the flat
    -- part and together lose LESS than one long leg, so a doorway made things louder, and the sign of
    -- the error flipped with distance. Free field over the true path, then take away, is predictable.
    local folded = Doors:DistanceGain(d1 + d2, cfg.level)
    local cross = folded * aperture * extra * directivity

    local target = sameSpace and direct or cross

    -- Changing space is the only real discontinuity, and it cannot be smoothed by blending the two
    -- gains: each is valid only in its own space. The moment you step out, the in-space one is
    -- measuring the emitter's world position across the void, so blending from it fades in from
    -- silence. Capture the step in dB at the instant it happens and heal that to nothing instead,
    -- which leaves ordinary distance changes completely alone.
    if self.was_sameSpace == nil then self.was_sameSpace = sameSpace end
    if sameSpace ~= self.was_sameSpace then
        self.heal_db = math.Clamp(toDb(self.last_target or target) - toDb(target), -60, 60)
        self.heal_left = TRANSITION_FLOOR
        self.was_sameSpace = sameSpace
    end
    self.last_target = target

    local gain, healing = target, 0
    if self.heal_left > 0 then
        self.heal_left = self.heal_left - FrameTime()
        healing = math.max(self.heal_left, 0) / TRANSITION_FLOOR
        gain = target * 10 ^ (self.heal_db * healing / 20)
    end

    i.ok, i.why = true, nil
    i.int, i.inside, i.sameSpace = int, inside, sameSpace
    i.openness, i.aperture, i.area, i.realArea = openness, aperture, area, realArea
    i.d1, i.d2, i.halvings, i.dbPer1000, i.extra = d1, d2, halvings, dbPer1000, extra
    i.facing, i.directivity = facing, directivity
    i.direct, i.folded, i.cross = direct, folded, cross
    i.gain, i.healing = gain, healing
    -- Distance from the sound along the path it actually travels. Measuring from the doorway instead
    -- makes the axis mean opposite things on the two sides - walking to the door is walking away from
    -- a sound in the middle of the room.
    i.path = sameSpace and EyePos():Distance(emitterPos) or (d1 + d2)
    i.pos = sameSpace and emitterPos or listenerMouth
    i.emitterPos, i.listenerMouth = emitterPos, listenerMouth
    i.listenerSide, i.sourceSide = listenerSide, sourceSide
    return i
end

--------------------------------------------------------------------------------------------------
-- Driving a real handle
--------------------------------------------------------------------------------------------------

function RIG:Play()
    self:Stop()
    local sample = self.samples[self.sel]
    if not sample then return end
    self.snd = Doors:PlaySound({ path = sample.path, pos = EyePos(), loop = true, volume = 0 })
end

function RIG:Stop()
    if IsValid(self.snd) then self.snd:Stop() end
    self.snd = nil
end

local function think()
    local ok, err = pcall(function()
        local i = RIG:Resolve()
        local h = RIG.snd
        -- `h ~= nil`, not IsValid: a handle's IsValid means "has a channel", and the channel loads
        -- asynchronously. Gating on it would skip exactly the frames before the load lands, so the
        -- volume would still be at its placeholder when the channel starts and jump a frame later.
        if h == nil or h.stopped or not i.ok then return end
        -- clearing the level stops the library applying its own distance gain on top of ours; pan,
        -- occlusion, the mixer constant and master volume stay the shipping path
        h.level = nil
        h.ent = nil
        h.pos = i.pos
        h.base = RIG.cfg.volume * i.gain
    end)
    if not ok then
        RIG:Close()
        ErrorNoHalt("cross-boundary sound debug stopped: " .. tostring(err) .. "\n")
    end
end

--------------------------------------------------------------------------------------------------
-- World markers
--------------------------------------------------------------------------------------------------

---@param side doors_sound_debug_side
---@param col table
local function drawMouth(side, col)
    local c = mouthCorners(side)
    for k = 1, 4 do
        render.DrawLine(c[k], c[k % 4 + 1], col, false)
    end
end

---@param _ boolean
---@param skybox boolean
local function draw3d(_, skybox)
    if skybox or not RIG.cfg.draw3d then return end
    pcall(function()
        local i = RIG.info
        if not i.ok then return end
        render.SetColorMaterial()

        local listener = i.listenerSide
        if listener then
            drawMouth(listener, Color(90, 200, 120))
            local c = listener.ent:LocalToWorld(listener.portal.pos)
            render.DrawLine(c, c + mouthNormal(listener) * 48, Color(90, 200, 120, 200), false)
        end
        if i.sourceSide and i.sourceSide ~= listener then
            drawMouth(i.sourceSide, Color(70, 120, 190))
        end

        -- Where the sound actually is - the emitter, not the doorway the model resolves it to, which
        -- across a boundary is a different room entirely. This runs inside portal passes too, so from
        -- outside it shows through the doorway, sitting where the sound really is.
        local loud = math.Clamp((toDb(i.gain) - DBFLOOR) / -DBFLOOR, 0, 1)
        render.DrawWireframeSphere(i.emitterPos, 12 + loud * 30, 12, 12,
            Color(255, 200 - loud * 140, 60, 255), false)
        render.DrawLine(i.emitterPos, i.emitterPos - Vector(0, 0, 96), Color(255, 200, 60, 120), false)

        -- and, small, where it is played from once through the doorway - what carries the direction
        if i.pos ~= i.emitterPos then
            render.DrawWireframeSphere(i.pos, 7, 6, 6, Color(120, 190, 240, 200), false)
        end

        -- The label rides in the world rather than on the HUD so it travels with the marker through a
        -- doorway; a screen projection is computed against the main view, so it would vanish exactly
        -- when the sound it belongs to is only visible through one.
        local face = Angle(0, EyeAngles().y - 90, 90)
        cam.Start3D2D(i.emitterPos + Vector(0, 0, 64), face,
            math.Clamp(EyePos():Distance(i.emitterPos) / 3000, 0.06, 0.6))
            draw.SimpleText(string.format("%.1f dB", toDb(i.gain)), "DermaLarge", 0, 0,
                Color(255, 220, 120), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            draw.SimpleText(string.format("%.0fu along the path", i.path), "DermaDefaultBold", 0, 26,
                Color(220, 220, 230), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        cam.End3D2D()
    end)
end

--------------------------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------------------------

function RIG:Close()
    self:Stop()
    hook.Remove("Think", "doors_debug_sound")
    hook.Remove("PostDrawTranslucentRenderables", "doors_debug_sound")
    if IsValid(self.frame) then self.frame:Remove() end
    self.frame = nil
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

    local f = (IsValid(cmenu) and cmenu:Add("DFrame") or vgui.Create("DFrame")) --[[@as DFrame]]
    self.frame = f
    f:SetSize(460, 720)
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
    ---@param key string
    local function slider(text, min, max, dec, key)
        local sl = scroll:Add("DNumSlider")
        sl:Dock(TOP) sl:DockMargin(6, 2, 6, 0)
        sl:SetText(text) sl:SetMinMax(min, max) sl:SetDecimals(dec) sl:SetValue(cfg[key])
        ---@param v number
        function sl:OnValueChanged(v) cfg[key] = v end
        widgets[#widgets + 1] = { sl, key }
    end
    ---@param text string
    ---@param key string
    local function check(text, key)
        local c = scroll:Add("DCheckBoxLabel")
        c:Dock(TOP) c:DockMargin(6, 6, 6, 0)
        c:SetText(text) c:SetValue(cfg[key])
        ---@param v boolean
        function c:OnChange(v) cfg[key] = v end
        widgets[#widgets + 1] = { c, key }
    end
    ---@param text string
    ---@param fn function
    local function button(text, fn)
        local b = scroll:Add("DButton")
        b:Dock(TOP) b:DockMargin(6, 4, 6, 0) b:SetTall(26) b:SetText(text)
        function b:DoClick() fn() end
    end

    label("Sound")
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

    button("PLAY", function() RIG:Play() end)
    button("Stop", function() RIG:Stop() end)

    label("Aperture - a flat gain, 1 when fully open")
    slider("closed coefficient", 0, 1, 3, "closed")
    slider("openness curve exponent", 0.25, 5, 2, "curve")

    label("What the doorway costs a sound coming through it")
    slider("dB per 1000u, per halving of the doorway", 0, 30, 2, "falloff")
    slider("how much it aims its sound (0 = every way)", 0, 1, 2, "aim")
    -- one interior gives one doorway, which makes the size term impossible to read on its own
    slider("pretend the doorway is this big (0 = actual)", 0, 30000, 0, "size_override")

    label("Sound level and volume")
    slider("SNDLVL", 40, 120, 0, "level")
    slider("caller volume", 0, 1, 2, "volume")

    label("Door")
    check("drive openness by hand", "manual")
    slider("openness", 0, 1, 3, "openness")
    check("mark the sound and doorway in the world", "draw3d")

    -- Two absolute numbers rather than a ratio: a ratio drifts as you walk for reasons that have
    -- nothing to do with the doorway. Left, how loud it is where you stand; right, what the doorway
    -- costs, which holds still while you move because it depends only on the tuning.
    local summary = scroll:Add("DPanel")
    summary:Dock(TOP) summary:DockMargin(6, 10, 6, 0) summary:SetTall(62)
    ---@param w number
    ---@param h number
    function summary:Paint(w, h)
        local i = RIG.info
        draw.RoundedBox(4, 0, 0, w, h, Color(26, 28, 34))
        if not i.ok then
            draw.SimpleText(i.why or "-", "DermaDefault", w / 2, h / 2, Color(150, 90, 90),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            return
        end
        local half = w / 2
        draw.SimpleText("you hear", "DermaDefault", half / 2, 13, Color(150, 155, 170),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(string.format("%.1f dB", toDb(i.gain)), "DermaLarge", half / 2, 34,
            Color(200, 215, 235), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(string.format("%.0fu from the sound", i.path), "DermaDefault", half / 2, 52,
            Color(130, 135, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        surface.SetDrawColor(60, 64, 76)
        surface.DrawRect(half, 8, 1, h - 16)
        draw.SimpleText("the doorway costs", "DermaDefault", half + half / 2, 13,
            Color(150, 155, 170), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(string.format("%.1f dB", toDb(i.aperture)), "DermaLarge", half + half / 2, 34,
            Color(110, 210, 130), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(string.format("door %.0f%% open", i.openness * 100), "DermaDefault",
            half + half / 2, 52, Color(130, 135, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- Level against distance FROM THE SOUND, along the path it travels, so walking in any direction
    -- moves the marker the way you would expect. One continuous curve: plain falloff up to the
    -- doorway, then the through-the-doorway falloff past it. The step down at the doorway line is the
    -- aperture and the widening gap to the faint line is the extra falloff, so both are visible at
    -- once. dB up the side, because linear gain squashes everything interesting into the bottom pixel.
    local plot = scroll:Add("DPanel")
    plot:Dock(TOP) plot:DockMargin(6, 6, 6, 0) plot:SetTall(180)
    ---@param w number
    ---@param h number
    function plot:Paint(w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(26, 28, 34))
        local i = RIG.info
        if not i.ok then return end
        local pad = 30
        local maxd = math.max(1200, i.path * 1.3)
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

        local lvl = RIG.cfg.level
        curve(1, i.d1, function(d) return Doors:DistanceGain(d, lvl) end, Color(110, 150, 220))
        curve(i.d1, maxd, function(d) return Doors:DistanceGain(d, lvl) end, Color(70, 85, 120))
        curve(i.d1, maxd, function(d)
            return Doors:DistanceGain(d, lvl) * i.aperture * i.directivity
                * 10 ^ (-(i.dbPer1000 * (d - i.d1) / 1000) / 20)
        end, Color(110, 210, 130))

        local dx = pad + pw * math.Clamp(i.d1 / maxd, 0, 1)
        surface.SetDrawColor(230, 190, 80, 120)
        surface.DrawRect(dx - 1, 10, 2, ph)
        draw.SimpleText("doorway", "DermaDefault", dx + 4, 12, Color(230, 190, 80))

        local mx = pad + pw * math.Clamp(i.path / maxd, 0, 1)
        surface.SetDrawColor(255, 255, 255, 200)
        surface.DrawRect(mx - 1, 10, 2, ph)
        surface.SetDrawColor(255, 255, 255)
        surface.DrawRect(mx - 3, ypos(i.gain) - 3, 6, 6)

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
        local c = RIG.cfg
        MsgN(string.format([[

-- tuned in doors_debug_sound
APERTURE_CLOSED  = %.3f   -- fully open is 1 by construction
APERTURE_CURVE   = %.2f
DOORWAY_FALLOFF  = %.2f   -- dB per 1000u per halving below %d square units
DOORWAY_AIM      = %.2f
]], c.closed, c.curve, c.falloff, SIZE_NEUTRAL, c.aim))
        chat.AddText("dumped to console")
    end)

    button("RESET TO DEFAULTS", function()
        for k, v in pairs(RIG.defaults) do RIG.cfg[k] = v end
        for _, entry in ipairs(widgets) do
            local pnl = entry[1]
            if IsValid(pnl) then pnl:SetValue(RIG.cfg[entry[2]]) end
        end
    end)
end

---@return string
function RIG:Stats()
    local i = self.info
    local out = {}
    ---@param k string
    ---@param v string
    local function line(k, v) out[#out + 1] = string.format("%-9s %s", k, v) end
    if not i.ok then
        line("STATE", i.why or "resolving")
        return table.concat(out, "\n")
    end
    line("LISTENER", (i.inside and "inside" or "outside")
        .. (i.sameSpace and " - same space as the sound, no doorway in the path" or ""))
    line("SETTLING", i.healing > 0
        and string.format("%.0f%% of a %.1f dB space change left to fade", i.healing * 100, self.heal_db)
        or "settled")
    line("PATH", string.format("emitter %.0fu -> doorway, doorway %.0fu -> you  (total %.0fu)",
        i.d1, i.d2, i.path))
    line("BASELINE", string.format("%.1f dB   free field over the whole path", toDb(i.folded)))
    line("APERTURE", string.format("%.1f dB   at %.0f%% open", toDb(i.aperture), i.openness * 100))
    line("FALLOFF", string.format("%.1f dB here   (%.2f dB/1000u = %.2f x %.2f halvings under %d)",
        toDb(i.extra), i.dbPer1000, self.cfg.falloff, i.halvings, SIZE_NEUTRAL))
    line("AIM", string.format("%.1f dB   facing %+.2f (%s)", toDb(i.directivity), i.facing,
        i.facing > 0.3 and "in front of it" or (i.facing < -0.3 and "round the back" or "edge on")))
    line("DOORWAY", string.format("%.0f square units%s", i.area,
        self.cfg.size_override > 0 and string.format(" FAKED, really %.0f", i.realArea) or ""))
    line("RESULT", string.format("%.1f dB playing   (through %.1f, in-space %.1f)",
        toDb(i.gain), toDb(i.cross), toDb(i.direct)))
    local h = self.snd
    if IsValid(h) then
        ---@cast h doors_managed_sound
        line("CHANNEL", string.format("base %.4f -> applied %.4f%s", h.base, h.volume,
            h.omni and "   stereo wav, so omni and unpanned" or ""))
    else
        line("CHANNEL", "nothing playing")
    end
    return table.concat(out, "\n")
end

concommand.Add("doors_debug_sound", function() RIG:Open(true) end)
