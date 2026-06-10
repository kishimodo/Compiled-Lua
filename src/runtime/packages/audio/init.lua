-- audio -- audio file decode + WAV encode.
--
-- WAV is parsed and emitted in pure Lua (handles PCM 8/16/24/32 + IEEE
-- float + mu-law + A-law). Everything else (MP3, FLAC, AAC, OGG, WMA,
-- M4A) goes through Media Foundation via the `mediafound` sub-package.
--
-- Decoded representation:
--   {
--     channels      = N,
--     sample_rate   = Hz,
--     sample_format = "s16"|"s24"|"s32"|"f32"|"u8",
--     samples       = bytes,           -- interleaved, native LE
--     frame_count   = #samples / (channels * bytes_per_sample),
--     duration      = frame_count / sample_rate,
--   }
--
-- Public surface:
--   audio.decode(bytes_or_path, opts?)   -> audio
--   audio.encode(audio, format, opts?)   -> string
--   audio.load(path, opts?)              -> audio
--   audio.save(audio, path, opts?)       -> nothing
--   audio.play(audio_or_path, opts?)     -> handle (PlaySoundW / WASAPI)
--   audio.stop()                         -> nothing  (any active PlaySound)
--   audio.resample(audio, target_rate)   -> audio
--   audio.gain(audio, db)                -> audio
--   audio.trim(audio, start_s, end_s?)   -> audio
--   audio.mix(audios)                    -> audio
--   audio.to_float(audio)                -> audio                  (sample_format = "f32")
--   audio.to_int16(audio)                -> audio                  (sample_format = "s16")
--   audio.info(bytes_or_path)            -> { ...minus samples... }

local ffi = ffi
local W   = require "windows"
local mf  = require "mediafound"

local C = ffi.C
local M = {}

-- ===== Optional WASAPI playback ========================================
local _wasapi_ok, _wasapi = pcall(require, "wasapi")
if not _wasapi_ok then _wasapi = nil end

-- ===== PlaySoundW fallback =============================================
-- winmm ships with every Windows install; PlaySoundW handles .wav files
-- and can also take an in-memory buffer with SND_MEMORY.
ffi.cdef[[
BOOL PlaySoundW(LPCWSTR pszSound, HMODULE hmod, DWORD fdwSound);
]]
pcall(ffi.load, "winmm")

local SND_ASYNC   = 0x00000001
local SND_MEMORY  = 0x00000004
local SND_LOOP    = 0x00000008
local SND_NODEFAULT = 0x00000002
local SND_SYNC    = 0x00000000

-- ===== I/O helpers =====================================================

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(data)
    f:close()
    return true
end

local function looks_like_path(s)
    if type(s) ~= "string" then return false end
    if #s == 0 or #s > 1024 then return false end
    if s:find("\0", 1, true) then return false end
    if s:sub(1, 4) == "RIFF" then return false end
    if s:sub(1, 4) == "OggS" then return false end
    if s:sub(1, 4) == "fLaC" then return false end
    if s:sub(1, 3) == "ID3"  then return false end
    if #s >= 2 and (s:byte(1) == 0xFF and (s:byte(2) & 0xE0) == 0xE0) then return false end
    return true
end

local function u32le(s, i) return s:byte(i) + s:byte(i+1)*256 + s:byte(i+2)*65536 + s:byte(i+3)*16777216 end
local function u16le(s, i) return s:byte(i) + s:byte(i+1)*256 end
local function put_u32le(v) return string.char(v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF) end
local function put_u16le(v) return string.char(v & 0xFF, (v >> 8) & 0xFF) end

-- ===== WAV decoder =====================================================
--
-- Walks the RIFF chunks looking for "fmt " then "data". Supports the
-- canonical PCM (1), float (3), mu-law (7) and A-law (6) formats, plus
-- the WAVEFORMATEXTENSIBLE container.

local function decode_wav(data)
    if #data < 44 then return nil, "wav: too short" end
    if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then
        return nil, "wav: bad RIFF header"
    end
    local pos = 13
    local fmt_format, fmt_channels, fmt_rate, fmt_bits, fmt_block = nil
    local data_blob
    while pos + 8 <= #data do
        local id = data:sub(pos, pos + 3)
        local sz = u32le(data, pos + 4)
        local body = data:sub(pos + 8, pos + 7 + sz)
        if id == "fmt " then
            fmt_format    = u16le(body, 1)
            fmt_channels  = u16le(body, 3)
            fmt_rate      = u32le(body, 5)
            fmt_block     = u16le(body, 13)
            fmt_bits      = u16le(body, 15)
            if fmt_format == 0xFFFE and sz >= 40 then
                -- WAVEFORMATEXTENSIBLE: the real subformat lives in the
                -- "SubFormat" GUID's first DWORD.
                fmt_format = u16le(body, 25)
            end
        elseif id == "data" then
            data_blob = body
        end
        local pad = sz % 2
        pos = pos + 8 + sz + pad
    end
    if not fmt_format then return nil, "wav: no fmt chunk" end
    if not data_blob   then return nil, "wav: no data chunk" end
    local sample_format
    if fmt_format == 1 then
        if     fmt_bits == 8  then sample_format = "u8"
        elseif fmt_bits == 16 then sample_format = "s16"
        elseif fmt_bits == 24 then sample_format = "s24"
        elseif fmt_bits == 32 then sample_format = "s32"
        else return nil, "wav: unsupported PCM bit depth " .. fmt_bits end
    elseif fmt_format == 3 then
        if fmt_bits == 32 then sample_format = "f32"
        elseif fmt_bits == 64 then sample_format = "f64"
        else return nil, "wav: unsupported float bit depth " .. fmt_bits end
    elseif fmt_format == 7 then
        sample_format = "ulaw"
    elseif fmt_format == 6 then
        sample_format = "alaw"
    else
        return nil, "wav: unsupported format tag " .. fmt_format
    end
    local bytes_per_sample = fmt_bits // 8
    local frame_bytes = fmt_channels * bytes_per_sample
    local frames = math.floor(#data_blob / frame_bytes)
    return {
        channels      = fmt_channels,
        sample_rate   = fmt_rate,
        sample_format = sample_format,
        samples       = data_blob,
        frame_count   = frames,
        duration      = frames / fmt_rate,
    }
end

-- ===== WAV encoder =====================================================

local function encode_wav(au)
    local sf = au.sample_format
    local format_tag, bits
    if     sf == "u8"   then format_tag, bits = 1, 8
    elseif sf == "s16"  then format_tag, bits = 1, 16
    elseif sf == "s24"  then format_tag, bits = 1, 24
    elseif sf == "s32"  then format_tag, bits = 1, 32
    elseif sf == "f32"  then format_tag, bits = 3, 32
    elseif sf == "f64"  then format_tag, bits = 3, 64
    else error("audio.encode_wav: unsupported sample_format " .. tostring(sf)) end
    local block = au.channels * (bits // 8)
    local byte_rate = au.sample_rate * block
    local data_size = #au.samples
    local fmt = put_u16le(format_tag)
            .. put_u16le(au.channels)
            .. put_u32le(au.sample_rate)
            .. put_u32le(byte_rate)
            .. put_u16le(block)
            .. put_u16le(bits)
    local fmt_chunk  = "fmt " .. put_u32le(#fmt) .. fmt
    local data_chunk = "data" .. put_u32le(data_size) .. au.samples
    local riff_body  = "WAVE" .. fmt_chunk .. data_chunk
    return "RIFF" .. put_u32le(#riff_body) .. riff_body
end

-- ===== Media Foundation decode (MP3/FLAC/AAC/M4A/OGG/WMA) ==============

local function decode_via_mf(path, opts)
    opts = opts or {}
    local reader = mf.reader_from_url(path)

    -- Ask MF to decode the audio stream into PCM 16-bit (or float on request).
    local want_float = opts.sample_format == "f32"
    if want_float then
        reader:set_native_format(mf.STREAM_FIRST_AUDIO,
            mf.MFMediaType_Audio, mf.MFAudioFormat_Float)
    else
        reader:set_native_format(mf.STREAM_FIRST_AUDIO,
            mf.MFMediaType_Audio, mf.MFAudioFormat_PCM)
    end

    local mt = reader:current_media_type(mf.STREAM_FIRST_AUDIO)
    local pieces = {}
    while true do
        local bytes, flags = reader:read(mf.STREAM_FIRST_AUDIO)
        if bytes == nil then break end  -- EOS
        if #bytes > 0 then pieces[#pieces + 1] = bytes end
    end
    reader:close()

    local samples = table.concat(pieces)
    local sf      = want_float and "f32" or ((mt.bits == 8 and "u8")
                  or (mt.bits == 24 and "s24")
                  or (mt.bits == 32 and "s32")
                  or "s16")
    local bytes_per_sample = (mt.bits or 16) // 8
    local frame_bytes = mt.channels * bytes_per_sample
    local frames = (frame_bytes > 0) and math.floor(#samples / frame_bytes) or 0
    return {
        channels      = mt.channels or 2,
        sample_rate   = mt.sample_rate or 44100,
        sample_format = sf,
        samples       = samples,
        frame_count   = frames,
        duration      = mt.sample_rate and (frames / mt.sample_rate) or 0,
    }
end

-- ===== Format inference ================================================

local function sniff_format(bytes)
    if #bytes < 4 then return "unknown" end
    if bytes:sub(1, 4) == "RIFF" then return "wav" end
    if bytes:sub(1, 4) == "OggS" then return "ogg" end
    if bytes:sub(1, 4) == "fLaC" then return "flac" end
    if bytes:sub(1, 3) == "ID3"  then return "mp3" end
    if #bytes >= 2 and bytes:byte(1) == 0xFF and (bytes:byte(2) & 0xE0) == 0xE0 then return "mp3" end
    if #bytes >= 8 and bytes:sub(5, 8) == "ftyp" then return "m4a" end
    return "unknown"
end

-- ===== Public API ======================================================

function M.decode(bytes_or_path, opts)
    opts = opts or {}
    -- Path branch: read into memory only if we need to detect the format
    -- by content. For non-WAV files we hand the path straight to MF so
    -- it can mmap / stream as it sees fit.
    if looks_like_path(bytes_or_path) or opts.is_path then
        local content = read_file(bytes_or_path)
        if content then
            local fmt = sniff_format(content)
            if fmt == "wav" then
                local au, err = decode_wav(content)
                if not au then error("audio.decode: " .. err) end
                return au
            end
            -- Anything else: defer to MF reading the path directly.
            return decode_via_mf(bytes_or_path, opts)
        end
    end
    -- Bytes branch.
    local fmt = sniff_format(bytes_or_path)
    if fmt == "wav" then
        local au, err = decode_wav(bytes_or_path)
        if not au then error("audio.decode: " .. err) end
        return au
    end
    -- For non-WAV blobs we have to materialise a temp file because
    -- MFCreateSourceReaderFromByteStream is a heavier setup than we want
    -- to wire here. Write to %TEMP%.
    local tmp = os.tmpname()
    -- os.tmpname on Windows yields a leading backslash without a drive;
    -- prefix the current TEMP directory.
    local temp_root = os.getenv("TEMP") or os.getenv("TMP") or "."
    local tmp_path = temp_root .. tmp .. "." .. fmt
    local ok, err = write_file(tmp_path, bytes_or_path)
    if not ok then error("audio.decode: cannot write temp file: " .. tostring(err)) end
    local result
    local pcall_ok, perr = pcall(function()
        result = decode_via_mf(tmp_path, opts)
    end)
    os.remove(tmp_path)
    if not pcall_ok then error("audio.decode: " .. tostring(perr)) end
    return result
end

function M.encode(au, format, opts)
    format = (format or "wav"):lower()
    if format == "wav" then return encode_wav(au) end
    error("audio.encode: only 'wav' supported by the pure-Lua encoder "
        .. "(decode covers mp3/flac/aac/m4a via Media Foundation)")
end

function M.info(bytes_or_path)
    local au = M.decode(bytes_or_path)
    return {
        channels      = au.channels,
        sample_rate   = au.sample_rate,
        sample_format = au.sample_format,
        frame_count   = au.frame_count,
        duration      = au.duration,
    }
end

function M.load(path, opts)
    opts = opts or {}; opts.is_path = true
    return M.decode(path, opts)
end

function M.save(au, path, opts)
    local bytes = M.encode(au, "wav", opts)
    local ok, err = write_file(path, bytes)
    if not ok then error("audio.save: " .. tostring(err)) end
end

-- ===== Sample-format conversion ========================================

local function bytes_per_sample(sf)
    if sf == "u8"   then return 1 end
    if sf == "s16"  then return 2 end
    if sf == "s24"  then return 3 end
    if sf == "s32"  then return 4 end
    if sf == "f32"  then return 4 end
    if sf == "f64"  then return 8 end
    error("audio: unknown sample_format " .. tostring(sf))
end

-- Read one sample at byte offset i (1-based) and return [-1.0, 1.0] float.
local function read_sample(samples, i, sf)
    if sf == "u8" then
        return (samples:byte(i) - 128) / 128.0
    elseif sf == "s16" then
        local lo, hi = samples:byte(i), samples:byte(i + 1)
        local v = lo + hi * 256
        if v >= 0x8000 then v = v - 0x10000 end
        return v / 32768.0
    elseif sf == "s24" then
        local b0, b1, b2 = samples:byte(i), samples:byte(i + 1), samples:byte(i + 2)
        local v = b0 + b1 * 256 + b2 * 65536
        if v >= 0x800000 then v = v - 0x1000000 end
        return v / 8388608.0
    elseif sf == "s32" then
        local b0, b1, b2, b3 = samples:byte(i), samples:byte(i + 1), samples:byte(i + 2), samples:byte(i + 3)
        local v = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
        if v >= 0x80000000 then v = v - 0x100000000 end
        return v / 2147483648.0
    elseif sf == "f32" then
        local p = ffi.cast("const float*", ffi.cast("const char*", samples) + (i - 1))
        return tonumber(p[0])
    elseif sf == "f64" then
        local p = ffi.cast("const double*", ffi.cast("const char*", samples) + (i - 1))
        return tonumber(p[0])
    end
end

local function write_sample(out, idx, v, sf)
    if v > 1 then v = 1 elseif v < -1 then v = -1 end
    if sf == "u8" then
        local b = math.floor(v * 127.5 + 128 + 0.5); if b > 255 then b = 255 end; if b < 0 then b = 0 end
        out[idx] = b
    elseif sf == "s16" then
        local s = math.floor(v * 32767 + 0.5)
        if s < -32768 then s = -32768 end; if s > 32767 then s = 32767 end
        if s < 0 then s = s + 0x10000 end
        out[idx]     = s & 0xFF
        out[idx + 1] = (s >> 8) & 0xFF
    elseif sf == "s24" then
        local s = math.floor(v * 8388607 + 0.5)
        if s < -8388608 then s = -8388608 end; if s > 8388607 then s = 8388607 end
        if s < 0 then s = s + 0x1000000 end
        out[idx]     = s & 0xFF
        out[idx + 1] = (s >> 8) & 0xFF
        out[idx + 2] = (s >> 16) & 0xFF
    elseif sf == "s32" then
        local s = math.floor(v * 2147483647 + 0.5)
        if s < -2147483648 then s = -2147483648 end; if s > 2147483647 then s = 2147483647 end
        if s < 0 then s = s + 0x100000000 end
        out[idx]     = s & 0xFF
        out[idx + 1] = (s >> 8) & 0xFF
        out[idx + 2] = (s >> 16) & 0xFF
        out[idx + 3] = (s >> 24) & 0xFF
    elseif sf == "f32" then
        local f = ffi.new("float[1]", v)
        local p = ffi.cast("uint8_t*", f)
        out[idx]     = p[0]; out[idx + 1] = p[1]; out[idx + 2] = p[2]; out[idx + 3] = p[3]
    end
end

local function convert_format(au, target)
    if au.sample_format == target then return au end
    local sf_in   = au.sample_format
    local bps_in  = bytes_per_sample(sf_in)
    local bps_out = bytes_per_sample(target)
    local total_samples = #au.samples // bps_in
    local out_bytes = total_samples * bps_out
    local buf = ffi.new("uint8_t[?]", out_bytes)
    for n = 0, total_samples - 1 do
        local v = read_sample(au.samples, n * bps_in + 1, sf_in)
        write_sample(buf, n * bps_out, v, target)
    end
    return {
        channels      = au.channels,
        sample_rate   = au.sample_rate,
        sample_format = target,
        samples       = ffi.string(buf, out_bytes),
        frame_count   = au.frame_count,
        duration      = au.duration,
    }
end

M.to_float = function(au) return convert_format(au, "f32") end
M.to_int16 = function(au) return convert_format(au, "s16") end
M.convert  = convert_format

-- ===== Sample-rate conversion (linear interpolation) ===================

function M.resample(au, target_rate)
    if au.sample_rate == target_rate then return au end
    local src = M.to_float(au)
    local in_frames = src.frame_count
    local ch        = src.channels
    local ratio     = target_rate / src.sample_rate
    local out_frames = math.floor(in_frames * ratio + 0.5)
    local sample_bytes = ffi.cast("const float*", src.samples)
    local out_floats = ffi.new("float[?]", out_frames * ch)
    for i = 0, out_frames - 1 do
        local src_pos = i / ratio
        local i0      = math.floor(src_pos)
        local frac    = src_pos - i0
        local i1      = i0 + 1
        if i1 >= in_frames then i1 = in_frames - 1 end
        for c = 0, ch - 1 do
            local a = sample_bytes[i0 * ch + c]
            local b = sample_bytes[i1 * ch + c]
            out_floats[i * ch + c] = a + (b - a) * frac
        end
    end
    return {
        channels      = ch,
        sample_rate   = target_rate,
        sample_format = "f32",
        samples       = ffi.string(out_floats, out_frames * ch * 4),
        frame_count   = out_frames,
        duration      = out_frames / target_rate,
    }
end

function M.gain(au, db)
    local linear = 10 ^ (db / 20)
    local src = M.to_float(au)
    local n   = #src.samples // 4
    local in_p  = ffi.cast("const float*", src.samples)
    local out_p = ffi.new("float[?]", n)
    for i = 0, n - 1 do out_p[i] = in_p[i] * linear end
    return {
        channels      = src.channels,
        sample_rate   = src.sample_rate,
        sample_format = "f32",
        samples       = ffi.string(out_p, n * 4),
        frame_count   = src.frame_count,
        duration      = src.duration,
    }
end

function M.trim(au, start_s, end_s)
    local frame_bytes = au.channels * bytes_per_sample(au.sample_format)
    local start_frame = math.floor((start_s or 0) * au.sample_rate)
    local end_frame   = end_s and math.floor(end_s * au.sample_rate) or au.frame_count
    if start_frame < 0 then start_frame = 0 end
    if end_frame > au.frame_count then end_frame = au.frame_count end
    if end_frame <= start_frame then
        return {
            channels = au.channels, sample_rate = au.sample_rate,
            sample_format = au.sample_format, samples = "",
            frame_count = 0, duration = 0,
        }
    end
    local cut = au.samples:sub(start_frame * frame_bytes + 1, end_frame * frame_bytes)
    return {
        channels      = au.channels,
        sample_rate   = au.sample_rate,
        sample_format = au.sample_format,
        samples       = cut,
        frame_count   = end_frame - start_frame,
        duration      = (end_frame - start_frame) / au.sample_rate,
    }
end

function M.mix(list)
    if #list == 0 then error("audio.mix: empty list") end
    -- Normalise everyone to f32 at the first track's sample rate / channel count.
    local first = M.to_float(list[1])
    local channels = first.channels
    local rate     = first.sample_rate
    local max_frames = first.frame_count
    local normalised = { first }
    for i = 2, #list do
        local cur = M.to_float(list[i])
        if cur.sample_rate ~= rate then cur = M.resample(cur, rate) end
        if cur.channels ~= channels then
            -- Naive channel mix: drop or duplicate.
            error("audio.mix: differing channel counts (" .. cur.channels
                .. " vs " .. channels .. ")")
        end
        normalised[#normalised + 1] = cur
        if cur.frame_count > max_frames then max_frames = cur.frame_count end
    end
    local total = max_frames * channels
    local out   = ffi.new("float[?]", total)
    for _, cur in ipairs(normalised) do
        local n = cur.frame_count * channels
        local p = ffi.cast("const float*", cur.samples)
        for j = 0, n - 1 do out[j] = out[j] + p[j] end
    end
    -- Soft-clip to [-1, 1] so mixing more than 2 tracks doesn't blow up.
    for j = 0, total - 1 do
        local v = out[j]
        if v >  1 then out[j] =  1
        elseif v < -1 then out[j] = -1 end
    end
    return {
        channels      = channels,
        sample_rate   = rate,
        sample_format = "f32",
        samples       = ffi.string(out, total * 4),
        frame_count   = max_frames,
        duration      = max_frames / rate,
    }
end

-- ===== Playback ========================================================
--
-- PlaySoundW is the simplest path: hands a WAV blob (or path) to the
-- multimedia subsystem and returns. For more sophisticated playback
-- (low-latency / format-negotiated / capture) callers should grab the
-- wasapi sub-package directly.

local _play_active

local function play_path(path, opts)
    opts = opts or {}
    local flags = SND_ASYNC | SND_NODEFAULT
    if opts.loop then flags = flags | SND_LOOP end
    if opts.sync then flags = (flags & (~SND_ASYNC)) | SND_SYNC end
    local n = #path
    local wpath = ffi.new("unsigned short[?]", n + 1)
    local got = C.MultiByteToWideChar(W.CP_UTF8, 0, path, n, wpath, n)
    if got <= 0 then
        for i = 1, n do wpath[i - 1] = path:byte(i) end
        wpath[n] = 0
    else wpath[got] = 0 end
    local ok = C.PlaySoundW(wpath, nil, flags)
    if ok == 0 then error("audio.play: PlaySoundW failed for " .. path) end
    _play_active = true
end

local function play_bytes(bytes, opts)
    opts = opts or {}
    local flags = SND_ASYNC | SND_MEMORY | SND_NODEFAULT
    if opts.loop then flags = flags | SND_LOOP end
    -- PlaySoundW reads from the buffer pointer as a WCHAR string; for
    -- SND_MEMORY it actually wants raw bytes (and the pointer type is a
    -- lie). Use a byte buffer that outlives the call.
    local buf = ffi.new("uint8_t[?]", #bytes, bytes)
    local ok = C.PlaySoundW(ffi.cast("LPCWSTR", buf), nil, flags)
    if ok == 0 then error("audio.play: PlaySoundW(memory) failed") end
    _play_active = buf  -- keep the buffer alive for the duration
end

function M.play(audio_or_path, opts)
    if type(audio_or_path) == "string" then
        -- Path or compressed bytes? If it starts with RIFF we feed it directly.
        if #audio_or_path >= 4 and audio_or_path:sub(1, 4) == "RIFF" then
            return play_bytes(audio_or_path, opts)
        end
        if looks_like_path(audio_or_path) then return play_path(audio_or_path, opts) end
        -- compressed in-memory blob: decode -> WAV -> bytes
        local au = M.decode(audio_or_path)
        return play_bytes(M.encode(au, "wav"), opts)
    end
    -- Audio table.
    local au = audio_or_path
    if au.sample_format ~= "s16" and au.sample_format ~= "u8" then
        au = M.to_int16(au)
    end
    return play_bytes(M.encode(au, "wav"), opts)
end

function M.stop()
    if _play_active then
        C.PlaySoundW(nil, nil, 0)
        _play_active = nil
    end
end

-- ===== WASAPI proxy ====================================================
-- For consumers that want streaming playback or capture, expose the
-- wasapi package directly so they don't have to require it themselves.
M.wasapi = _wasapi

return M
