-- Reading a .wav's header, and building the trimmed loop body a marked-up file needs.
--
-- Chunks are walked rather than read at canonical offsets, so a file with extra chunks (LIST/fact/JUNK)
-- before `fmt ` still reads correctly. Every read is bounded: a truncated or half-mounted file otherwise
-- walks off the end, where string.byte gives nil and the arithmetic raises inside a Think.

---@class doors_sound_module
---@field header fun(path: string): doors_wav_header
---@field loop_body_file fun(path: string, from: number): string?
---@field handover number

local Sound = Doors.Sound

--------------------------------------------------------------------------------------------------
-- Header
--------------------------------------------------------------------------------------------------

-- Channel count matters because Source plays a positioned STEREO .wav as CHAR_OMNI (S_SetChannelStereo,
-- snd_dma.cpp): full mono, distance-attenuated only, never occluded. A stereo OGG/MP3 is not omni
-- (IsStereoWav excludes them) and spatialises normally.
--
-- The loop point matters because the engine loops a .wav from the marker its author baked in, not from
-- the start, while BASS's own looping always wraps to sample 0 - which would replay an intro every cycle.
---@param data string
---@return number? channels nil if not a parseable WAV
---@return number? loopStartSamples nil if the file carries no loop marker
---@return number? sampleRate
local function wavInfo(data)
    if #data < 16 or data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then return nil end
    ---@param o number
    ---@return number
    local function u32(o)
        return data:byte(o) + data:byte(o+1)*256 + data:byte(o+2)*65536 + data:byte(o+3)*16777216
    end
    local channels, rate, loopStart
    local pos = 13 -- first chunk id (byte 13 = file offset 12)
    while pos + 8 <= #data do
        local id, size = data:sub(pos, pos + 3), u32(pos + 4)
        local body = pos + 8
        if id == "fmt " and body + 11 <= #data then
            channels = data:byte(body + 2) + data:byte(body + 3) * 256 -- audioFormat(2), then channels(2)
            rate = u32(body + 4)
        elseif id == "smpl" and body + 35 <= #data then
            local loops = u32(body + 28)
            if loops > 0 and body + 47 <= #data then
                loopStart = u32(body + 44) -- first loop's dwStart
            end
        elseif id == "cue " and body + 3 <= #data then
            local n = u32(body)
            for i = 0, math.min(n, 64) - 1 do
                local off = body + 4 + i * 24 + 20 -- dwSampleOffset within the cue point
                if off + 3 <= #data then
                    local s = u32(off)
                    loopStart = loopStart and math.min(loopStart, s) or s
                end
            end
        end
        pos = body + size + (size % 2) -- chunks are word-aligned
    end
    return channels, loopStart, rate
end

---@class doors_wav_header
---@field omni boolean stereo .wav, which Source plays omnidirectional
---@field loop_start number seconds into the file its baked-in loop marker starts at, 0 if none
---@field mtime number the source's modified time when parsed, so a live edit re-reads
---@field duration number? one-shot length in seconds, learned from the channel and cached per path

local cache = {} ---@type table<string, doors_wav_header>

-- Keyed on the modified time so a live-edited .wav reparses. An OGG caches a constant (nothing to go
-- stale) and packed files report 0, so both stay cached exactly as before.
---@param path string sound path relative to sound/
---@return doors_wav_header
local function wavHeader(path)
    local isWav = string.EndsWith(path:lower(), ".wav")
    local mtime = isWav and file.Time("sound/" .. path, "GAME") or 0
    local cached = cache[path]
    if cached and cached.mtime == mtime then return cached end
    local info = { omni = false, loop_start = 0, mtime = mtime }
    if isWav then
        local data = file.Read("sound/" .. path, "GAME")
        if data == nil then
            -- unreadable .wav (a mount file.Read can't reach): assume stereo, since almost every one
            -- is, so it defaults to omni like Source treats a stereo wav
            info.omni = true
        else
            local channels, loopStart, rate = wavInfo(data)
            info.omni = channels == 2
            if loopStart and rate and rate > 0 then
                -- a marker inside its own handover would never be heard, and those are encoder
                -- artefacts rather than authored intros: treat it as a plain whole-file loop
                local secs = loopStart / rate
                info.loop_start = secs > Sound.handover and secs or 0
            end
        end
    end
    cache[path] = info
    return info
end
Sound.header = wavHeader

--------------------------------------------------------------------------------------------------
-- Loop body
--------------------------------------------------------------------------------------------------

-- A file whose loop begins partway in can't be looped correctly by BASS, and no amount of seeking from
-- Lua fixes that, because the position we can observe isn't the one being heard. So hand BASS a file
-- that *is* the loop: copy the samples from the marker onwards into data/ once, and loop that whole-file.
-- PCM wav only, which is all that carries a marker anyway. The cache key is the source content, so any
-- edit rebuilds it - even one that leaves the file the same size.
---@param path string
---@param from number seconds to trim off the front
---@return string? dataPath relative to data/, nil if the file can't be trimmed
local function loopBodyFile(path, from)
    local src = file.Read("sound/" .. path, "GAME")
    if not src then return nil end
    local key = "doors_loopcache/" .. util.CRC(path .. "_" .. src) .. ".wav"
    if file.Exists(key, "DATA") then return key end
    if #src < 16 or src:sub(1, 4) ~= "RIFF" or src:sub(9, 12) ~= "WAVE" then return nil end

    ---@param o number
    ---@return number
    local function u(o) return src:byte(o) + src:byte(o+1)*256 + src:byte(o+2)*65536 + src:byte(o+3)*16777216 end
    local pos, fmtChunk, dataOff, dataLen, rate, channels, bits = 13, nil, nil, nil, 0, 0, 0
    while pos + 8 <= #src do
        local id, size = src:sub(pos, pos + 3), u(pos + 4)
        local last = pos + 8 + size - 1 -- final byte of this chunk
        if id == "fmt " and size >= 16 and last <= #src then
            fmtChunk = src:sub(pos, last)
            channels = src:byte(pos + 10) + src:byte(pos + 11) * 256
            rate = u(pos + 12)
            bits = src:byte(pos + 22) + src:byte(pos + 23) * 256
        elseif id == "data" then
            -- clamped to what is present, so a length field overrunning the file can't describe a body
            -- that isn't there
            dataOff, dataLen = pos + 8, math.min(size, #src - pos - 7)
        end
        pos = pos + 8 + size + (size % 2)
    end
    if not (fmtChunk and dataOff and dataLen and rate > 0 and bits > 0 and channels > 0) then return nil end

    local frameBytes = (bits / 8) * channels
    local body = src:sub(dataOff + math.floor(from * rate) * frameBytes, dataOff + dataLen - 1)
    if #body < frameBytes then return nil end
    ---@param v number
    ---@return string
    local function n(v)
        return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256,
            math.floor(v / 16777216) % 256)
    end
    file.CreateDir("doors_loopcache")
    file.Write(key, "RIFF" .. n(4 + #fmtChunk + 8 + #body) .. "WAVE" .. fmtChunk .. "data" .. n(#body) .. body)
    return file.Exists(key, "DATA") and key or nil
end
Sound.loop_body_file = loopBodyFile
