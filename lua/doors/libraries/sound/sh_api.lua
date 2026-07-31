---@class doors_sound_opts
---@field path string sound path relative to sound/
---@field ent Entity?
---@field pos Vector? fixed world position, when there is no entity
---@field offset Vector? local offset from ent
---@field volume number? 0-1
---@field level number? SNDLVL
---@field resumable boolean? play on a managed channel, so it survives the listener crossing the void
---@field loop boolean? repeat from the file's own loop marker; implies resumable
---@field owner Entity? for group-stop via Doors:StopSounds, and stops with the owner
---@field tag string? group label for Doors:StopSounds
---@field pair string? one side of a sound authored twice, once per side of a boundary; scoped to owner
---@field through_doors number? 0-1 of this sound that carries across the boundary anyway
---@field pin_on_jump number? units/second past which a teleporting emitter leaves its tail behind
---@field attach Entity? takes over as the source once it arrives within attach_dist of pos
---@field attach_dist number? arrival distance for attach

if SERVER then
    util.AddNetworkString("Doors-Sound")
    util.AddNetworkString("Doors-SoundStop")
end

---@param opts doors_sound_opts
local function playNative(opts)
    if opts.ent == nil and opts.pos == nil then
        if CLIENT then surface.PlaySound(opts.path) end
        return
    end
    local ent = opts.ent
    if IsValid(ent) then
        if opts.offset then
            sound.Play(opts.path, ent:LocalToWorld(opts.offset), opts.level, nil, opts.volume)
        else
            ent:EmitSound(opts.path, opts.level, nil, opts.volume)
        end
    elseif opts.pos then
        sound.Play(opts.path, opts.pos, opts.level, nil, opts.volume)
    end
end

---@param opts doors_sound_opts
local function broadcast(opts)
    net.Start("Doors-Sound")
    net.WriteString(opts.path)
    net.WriteEntity(opts.owner or NULL)
    net.WriteString(opts.tag or "")
    net.WriteFloat(opts.volume or 1)
    net.WriteEntity(opts.ent or NULL)
    local pos = opts.pos or (IsValid(opts.ent) and opts.ent:GetPos() or nil)
    net.WriteBool(pos ~= nil)
    if pos then net.WriteVector(pos) end
    net.WriteBool(opts.offset ~= nil)
    if opts.offset then net.WriteVector(opts.offset) end
    net.WriteBool(opts.level ~= nil)
    if opts.level then net.WriteUInt(opts.level, 8) end
    net.WriteBool(opts.resumable == true)
    net.WriteBool(opts.loop == true)
    net.WriteString(opts.pair or "")
    net.WriteBool(opts.through_doors ~= nil)
    if opts.through_doors then net.WriteFloat(opts.through_doors) end
    net.WriteBool(opts.pin_on_jump ~= nil)
    if opts.pin_on_jump then net.WriteFloat(opts.pin_on_jump) end
    net.WriteEntity(opts.attach or NULL)
    net.WriteBool(opts.attach_dist ~= nil)
    if opts.attach_dist then net.WriteFloat(opts.attach_dist) end
    net.Broadcast()
end

---@api
---@param opts doors_sound_opts
---@return doors_managed_sound? handle
function Doors:PlaySound(opts)
    local managed = opts.resumable or opts.loop
    if CLIENT then
        if managed then return Doors.Sound.play(opts) end
        playNative(opts)
        return
    end
    if not (managed or (opts.ent == nil and opts.pos == nil)) then
        playNative(opts)
        return
    end
    broadcast(opts)
end

---@api
---@param owner Entity
---@param tag string?
function Doors:StopSounds(owner, tag)
    if SERVER then
        net.Start("Doors-SoundStop")
        net.WriteEntity(owner)
        net.WriteString(tag or "")
        net.Broadcast()
        return
    end
    local list = Doors.Sound.active
    for i = #list, 1, -1 do
        local handle = list[i]
        if handle.owner == owner and (tag == nil or handle.tag == tag) then
            handle:Stop()
        end
    end
end

if CLIENT then
    net.Receive("Doors-Sound", function()
        local path = net.ReadString()
        local owner = net.ReadEntity()
        local tag = net.ReadString()
        local volume = net.ReadFloat()
        local ent = net.ReadEntity()
        local pos = net.ReadBool() and net.ReadVector() or nil
        local offset = net.ReadBool() and net.ReadVector() or nil
        local level = net.ReadBool() and net.ReadUInt(8) or nil
        local resumable = net.ReadBool()
        local loop = net.ReadBool()
        local pair = net.ReadString()
        local through_doors = net.ReadBool() and net.ReadFloat() or nil
        local pin_on_jump = net.ReadBool() and net.ReadFloat() or nil
        local attach = net.ReadEntity()
        local attach_dist = net.ReadBool() and net.ReadFloat() or nil
        Doors:PlaySound({
            path = path,
            owner = IsValid(owner) and owner or nil,
            tag = tag ~= "" and tag or nil,
            volume = volume,
            ent = IsValid(ent) and ent or nil,
            pos = pos,
            offset = offset,
            level = level,
            resumable = resumable,
            loop = loop,
            pair = pair ~= "" and pair or nil,
            through_doors = through_doors,
            pin_on_jump = pin_on_jump,
            attach = IsValid(attach) and attach or nil,
            attach_dist = attach_dist,
        })
    end)

    net.Receive("Doors-SoundStop", function()
        local owner = net.ReadEntity()
        local tag = net.ReadString()
        if not IsValid(owner) then return end
        Doors:StopSounds(owner, tag ~= "" and tag or nil)
    end)
end
