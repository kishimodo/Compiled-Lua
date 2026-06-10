-- ffmpeg -- libav* bindings (lazy-loaded).
--
-- All DLLs are loaded on demand. require()-ing the package never fails.
-- The cdef block describes the subset we actually call -- demux, decode,
-- encode, swscale, swresample, probe, plus a high-level wrapper for the
-- common one-shot tasks (transcode, concat, cut, thumbnail).
--
-- Public surface:
--   ffmpeg.available()                            -> bool
--   ffmpeg.version()                              -> { avformat, avcodec, ... }
--   ffmpeg.probe(path)                            -> { duration, format, streams[], metadata }
--   ffmpeg.info(path)                             alias for probe
--   ffmpeg.convert(in_path, out_path, opts?)      -> nothing      (transmux / transcode)
--   ffmpeg.extract_audio(video, audio_out, opts?) -> nothing
--   ffmpeg.thumbnail(video, image_out, opts?)     -> nothing
--   ffmpeg.cut(in_path, out_path, start, finish)  -> nothing
--   ffmpeg.concat(in_paths, out_path, opts?)      -> nothing      (uses concat demuxer)
--   ffmpeg.frames(path, opts?)                    -> iterator(frame_obj)
--
-- opts table (transcode / extract / thumbnail):
--   video_codec   = "libx264" | "copy" | ...
--   audio_codec   = "aac" | "copy" | ...
--   video_bitrate = number (bits/sec)
--   audio_bitrate = number
--   scale         = { w, h }   -- preserves AR if either is -1
--   fps           = number
--   time          = number     -- thumbnail seek seconds
--   width / height            -- thumbnail dims (overrides scale)

local ffi = ffi

local M = {}

-- ===== cdef ============================================================
--
-- We model only the structs we read fields from. For pointer-only types
-- (opaque to us) we use forward declarations. Field order matches
-- ffmpeg 6.x; older 5.x layouts mostly agree on the head of each struct
-- which is all we touch.

ffi.cdef[[
typedef struct AVFormatContext  AVFormatContext;
typedef struct AVCodecContext   AVCodecContext;
typedef struct AVCodec          AVCodec;
typedef struct AVCodecParameters AVCodecParameters;
typedef struct AVStream         AVStream;
typedef struct AVPacket         AVPacket;
typedef struct AVFrame          AVFrame;
typedef struct AVDictionary     AVDictionary;
typedef struct AVDictionaryEntry {
    char *key;
    char *value;
} AVDictionaryEntry;
typedef struct AVRational { int num; int den; } AVRational;
typedef struct AVIOContext      AVIOContext;
typedef struct AVInputFormat    AVInputFormat;
typedef struct AVOutputFormat   AVOutputFormat;
typedef struct SwsContext       SwsContext;
typedef struct SwrContext       SwrContext;
typedef struct AVBSFContext     AVBSFContext;
typedef struct AVFilterGraph    AVFilterGraph;
typedef struct AVChannelLayout  AVChannelLayout;

/* libavutil */
unsigned avutil_version(void);
unsigned avcodec_version(void);
unsigned avformat_version(void);
unsigned swscale_version(void);
unsigned swresample_version(void);
const char *av_version_info(void);

void  av_log_set_level(int level);
void *av_malloc(size_t size);
void  av_free(void *ptr);
void  av_freep(void *ptr);
AVFrame *av_frame_alloc(void);
void     av_frame_free(AVFrame **frame);
int      av_frame_get_buffer(AVFrame *frame, int align);
int      av_frame_make_writable(AVFrame *frame);

AVPacket *av_packet_alloc(void);
void      av_packet_free(AVPacket **pkt);
void      av_packet_unref(AVPacket *pkt);

AVDictionaryEntry *av_dict_get(const AVDictionary *m, const char *key,
                               const AVDictionaryEntry *prev, int flags);
int               av_dict_set(AVDictionary **pm, const char *key,
                              const char *value, int flags);
void              av_dict_free(AVDictionary **pm);

int64_t av_rescale_q(int64_t a, AVRational bq, AVRational cq);

/* libavformat */
void avformat_network_init(void);
AVFormatContext *avformat_alloc_context(void);
void             avformat_free_context(AVFormatContext *s);
int  avformat_open_input(AVFormatContext **ps, const char *url,
                         const AVInputFormat *fmt, AVDictionary **options);
void avformat_close_input(AVFormatContext **s);
int  avformat_find_stream_info(AVFormatContext *ic, AVDictionary **options);
int  av_read_frame(AVFormatContext *s, AVPacket *pkt);
int  av_seek_frame(AVFormatContext *s, int stream_index, int64_t timestamp, int flags);
int  avformat_seek_file(AVFormatContext *s, int stream_index, int64_t min_ts,
                        int64_t ts, int64_t max_ts, int flags);
int  av_find_best_stream(AVFormatContext *ic, int type, int wanted_stream_nb,
                         int related_stream, const AVCodec **decoder_ret, int flags);

int  avformat_alloc_output_context2(AVFormatContext **ctx,
                                    const AVOutputFormat *oformat,
                                    const char *format_name,
                                    const char *filename);
int  avio_open(AVIOContext **s, const char *url, int flags);
int  avio_closep(AVIOContext **s);
int  avformat_write_header(AVFormatContext *s, AVDictionary **options);
int  av_write_frame(AVFormatContext *s, AVPacket *pkt);
int  av_interleaved_write_frame(AVFormatContext *s, AVPacket *pkt);
int  av_write_trailer(AVFormatContext *s);
AVStream *avformat_new_stream(AVFormatContext *s, const AVCodec *c);

/* libavcodec */
const AVCodec *avcodec_find_decoder(int id);
const AVCodec *avcodec_find_encoder(int id);
const AVCodec *avcodec_find_encoder_by_name(const char *name);
AVCodecContext *avcodec_alloc_context3(const AVCodec *codec);
void avcodec_free_context(AVCodecContext **avctx);
int  avcodec_parameters_to_context(AVCodecContext *codec, const AVCodecParameters *par);
int  avcodec_parameters_from_context(AVCodecParameters *par, const AVCodecContext *codec);
int  avcodec_open2(AVCodecContext *avctx, const AVCodec *codec, AVDictionary **options);
int  avcodec_send_packet(AVCodecContext *avctx, const AVPacket *avpkt);
int  avcodec_receive_frame(AVCodecContext *avctx, AVFrame *frame);
int  avcodec_send_frame(AVCodecContext *avctx, const AVFrame *frame);
int  avcodec_receive_packet(AVCodecContext *avctx, AVPacket *avpkt);

/* libswscale */
SwsContext *sws_getContext(int srcW, int srcH, int srcFormat,
                           int dstW, int dstH, int dstFormat,
                           int flags, void *srcFilter, void *dstFilter,
                           const double *param);
void sws_freeContext(SwsContext *swsContext);
int  sws_scale(SwsContext *c, const uint8_t * const srcSlice[],
               const int srcStride[], int srcSliceY, int srcSliceH,
               uint8_t * const dst[], const int dstStride[]);

/* libswresample */
SwrContext *swr_alloc(void);
void        swr_free(SwrContext **s);
int         swr_init(SwrContext *s);
int         swr_convert(SwrContext *s, uint8_t **out, int out_count,
                        const uint8_t **in, int in_count);
]]

-- ===== Reduced AVFormatContext / AVStream / AVCodecParameters =========
--
-- These structs are large and version-dependent; rather than declare
-- every field we read the head via offsetof-equivalent ffi.offsetof
-- calls and stop. We only need the few fields below.

ffi.cdef[[
struct AVFormatContext {
    const void *av_class;
    const AVInputFormat *iformat;
    const AVOutputFormat *oformat;
    void *priv_data;
    AVIOContext *pb;
    int ctx_flags;
    unsigned int nb_streams;
    AVStream **streams;
    /* trailing fields elided; we don't touch them */
};

struct AVStream {
    const void *av_class;
    int index;
    int id;
    AVCodecParameters *codecpar;
    void *priv_data;
    AVRational time_base;
    int64_t start_time;
    int64_t duration;
    int64_t nb_frames;
    /* trailing fields elided */
};

struct AVCodecParameters {
    int codec_type;
    int codec_id;
    uint32_t codec_tag;
    uint8_t *extradata;
    int extradata_size;
    int format;
    int64_t bit_rate;
    int bits_per_coded_sample;
    int bits_per_raw_sample;
    int profile;
    int level;
    int width;
    int height;
    AVRational sample_aspect_ratio;
    /* (long tail of fields)
       For our reads we go through codec_id / width / height / format /
       sample_rate / channels via fixed offsets, so any later fields are
       harmless even if the upstream layout shifted. */
};
]]

-- ===== Lazy DLL loader =================================================

local _libs = {}
local _load_err

-- Each av* DLL ships under a versioned name. We probe the canonical
-- 60/58/59/61 sequence (ffmpeg 4.x..7.x).
local _candidates = {
    avformat   = { "avformat-61", "avformat-60", "avformat-59", "avformat-58", "avformat" },
    avcodec    = { "avcodec-61",  "avcodec-60",  "avcodec-59",  "avcodec-58",  "avcodec"  },
    avutil     = { "avutil-59",   "avutil-58",   "avutil-57",   "avutil-56",   "avutil"   },
    swscale    = { "swscale-8",   "swscale-7",   "swscale-6",   "swscale-5",   "swscale"  },
    swresample = { "swresample-5","swresample-4","swresample-3","swresample"             },
}

local function load_lib(kind)
    if _libs[kind] then return _libs[kind] end
    for _, name in ipairs(_candidates[kind]) do
        local ok, lib = pcall(ffi.load, name)
        if ok then _libs[kind] = lib; return lib end
    end
    return nil
end

local function load_all()
    if _load_err then return false end
    local missing = {}
    for kind, _ in pairs(_candidates) do
        if not load_lib(kind) then missing[#missing + 1] = kind end
    end
    if #missing > 0 then
        _load_err = "missing ffmpeg DLLs: " .. table.concat(missing, ", ")
        return false
    end
    return true
end

function M.available()
    return load_all()
end

local function require_libs()
    if not load_all() then
        error("ffmpeg: " .. (_load_err or "DLLs not loaded"), 3)
    end
end

local function unpack_version(v)
    return {
        major = (v >> 16) & 0xFF,
        minor = (v >> 8)  & 0xFF,
        micro = v & 0xFF,
    }
end

function M.version()
    require_libs()
    local fmt  = _libs.avformat
    local cod  = _libs.avcodec
    local utl  = _libs.avutil
    local sw   = _libs.swscale
    local swr  = _libs.swresample
    return {
        avformat   = unpack_version(tonumber(fmt.avformat_version())),
        avcodec    = unpack_version(tonumber(cod.avcodec_version())),
        avutil     = unpack_version(tonumber(utl.avutil_version())),
        swscale    = unpack_version(tonumber(sw.swscale_version())),
        swresample = unpack_version(tonumber(swr.swresample_version())),
        build      = ffi.string(utl.av_version_info()),
    }
end

-- ===== Constants =======================================================

M.AVMEDIA_TYPE_VIDEO    = 0
M.AVMEDIA_TYPE_AUDIO    = 1
M.AVMEDIA_TYPE_DATA     = 2
M.AVMEDIA_TYPE_SUBTITLE = 3

M.AVIO_FLAG_READ  = 1
M.AVIO_FLAG_WRITE = 2

M.AVSEEK_FLAG_BACKWARD = 1
M.AVSEEK_FLAG_BYTE     = 2
M.AVSEEK_FLAG_ANY      = 4

-- AVPixelFormat: only the values we use directly.
M.AV_PIX_FMT_RGB24   = 2
M.AV_PIX_FMT_BGR24   = 3
M.AV_PIX_FMT_RGBA    = 26
M.AV_PIX_FMT_BGRA    = 28
M.AV_PIX_FMT_YUV420P = 0

-- Subset of AVCodecID values we name in errors.
M.AV_CODEC_ID_MJPEG  = 7
M.AV_CODEC_ID_PNG    = 61
M.AV_CODEC_ID_H264   = 27
M.AV_CODEC_ID_AAC    = 86018

local AVERROR_EOF      = -541478725  -- ('EOF ' tag)
local AVERROR_EAGAIN   = -11
M.AVERROR_EOF    = AVERROR_EOF
M.AVERROR_EAGAIN = AVERROR_EAGAIN

-- ===== Error helper ====================================================

local function check_av(ret, where)
    if ret < 0 then
        error(string.format("ffmpeg: %s failed (rc=%d)", where, tonumber(ret)), 3)
    end
    return ret
end

local function av_log_quiet()
    local utl = load_lib("avutil")
    if utl then pcall(function() utl.av_log_set_level(16) end) end  -- ERROR
end

-- ===== Probe / info ====================================================

local function open_input(path)
    require_libs()
    av_log_quiet()
    local fmt = _libs.avformat
    local ctxpp = ffi.new("AVFormatContext*[1]")
    local rc = fmt.avformat_open_input(ctxpp, path, nil, nil)
    if rc < 0 then
        error(string.format("ffmpeg: avformat_open_input(%q) failed (rc=%d)", path, rc), 3)
    end
    rc = fmt.avformat_find_stream_info(ctxpp[0], nil)
    if rc < 0 then
        fmt.avformat_close_input(ctxpp)
        error("ffmpeg: avformat_find_stream_info failed", 3)
    end
    return ctxpp
end

local function close_input(ctxpp)
    local fmt = _libs.avformat
    fmt.avformat_close_input(ctxpp)
end

local function read_metadata(dict)
    local fmt = _libs.avformat  -- av_dict_get lives in avutil but is re-exported
    if not dict or dict == nil then return {} end
    local utl = _libs.avutil
    local out  = {}
    local prev = nil
    while true do
        prev = utl.av_dict_get(dict, "", prev, 2)  -- AV_DICT_IGNORE_SUFFIX
        if prev == nil then break end
        out[ffi.string(prev.key)] = ffi.string(prev.value)
    end
    return out
end

function M.probe(path)
    local ctxpp = open_input(path)
    local fc    = ctxpp[0]
    local nb = tonumber(fc.nb_streams)
    local streams = {}
    local max_duration = 0
    for i = 0, nb - 1 do
        local s = fc.streams[i]
        local cp = s.codecpar
        local tb_num = tonumber(s.time_base.num)
        local tb_den = tonumber(s.time_base.den)
        local secs = 0
        if tb_den and tb_den ~= 0 and s.duration > 0 then
            secs = tonumber(s.duration) * tb_num / tb_den
        end
        if secs > max_duration then max_duration = secs end
        local info = {
            index      = tonumber(s.index),
            codec_type = tonumber(cp.codec_type),
            codec_id   = tonumber(cp.codec_id),
            bit_rate   = tonumber(cp.bit_rate),
            width      = tonumber(cp.width),
            height     = tonumber(cp.height),
            time_base  = { num = tb_num, den = tb_den },
            duration   = secs,
        }
        if info.codec_type == M.AVMEDIA_TYPE_VIDEO then info.kind = "video"
        elseif info.codec_type == M.AVMEDIA_TYPE_AUDIO then info.kind = "audio"
        elseif info.codec_type == M.AVMEDIA_TYPE_SUBTITLE then info.kind = "subtitle"
        else info.kind = "other" end
        streams[#streams + 1] = info
    end
    local out = {
        path     = path,
        duration = max_duration,
        streams  = streams,
        format   = (fc.iformat ~= nil) and "ok" or "?",
    }
    close_input(ctxpp)
    return out
end

M.info = M.probe

-- ===== Decoder helper ==================================================

local function open_decoder(stream)
    local cod = _libs.avcodec
    local codec = cod.avcodec_find_decoder(stream.codecpar.codec_id)
    if codec == nil then
        error(string.format("ffmpeg: no decoder for codec_id %d",
              tonumber(stream.codecpar.codec_id)), 3)
    end
    local cctx = cod.avcodec_alloc_context3(codec)
    if cctx == nil then error("ffmpeg: avcodec_alloc_context3 returned NULL", 3) end
    check_av(cod.avcodec_parameters_to_context(cctx, stream.codecpar),
             "avcodec_parameters_to_context")
    check_av(cod.avcodec_open2(cctx, codec, nil), "avcodec_open2")
    return cctx, codec
end

-- ===== Frame iterator ==================================================

function M.frames(path, opts)
    opts = opts or {}
    local ctxpp = open_input(path)
    local fc = ctxpp[0]
    local want = opts.media or "video"
    local target_type = (want == "audio") and M.AVMEDIA_TYPE_AUDIO or M.AVMEDIA_TYPE_VIDEO
    local stream_idx = -1
    for i = 0, tonumber(fc.nb_streams) - 1 do
        if tonumber(fc.streams[i].codecpar.codec_type) == target_type then
            stream_idx = i; break
        end
    end
    if stream_idx < 0 then
        close_input(ctxpp)
        error("ffmpeg.frames: no stream of type '" .. want .. "' in " .. path, 2)
    end
    local stream = fc.streams[stream_idx]
    local cctx, codec = open_decoder(stream)
    local cod = _libs.avcodec

    local utl   = _libs.avutil
    local pkt   = cod.av_packet_alloc()
    local frame = utl.av_frame_alloc()

    local fmtlib = _libs.avformat
    local closed = false
    local function cleanup()
        if closed then return end
        closed = true
        local pp = ffi.new("AVPacket*[1]")
        pp[0] = pkt
        cod.av_packet_free(pp)
        local fp = ffi.new("AVFrame*[1]")
        fp[0] = frame
        utl.av_frame_free(fp)
        local ccp = ffi.new("AVCodecContext*[1]")
        ccp[0] = cctx
        cod.avcodec_free_context(ccp)
        close_input(ctxpp)
    end

    -- The frames iterator yields a small handle per decoded frame. We
    -- can't easily extract the AVFrame fields without a more complete
    -- struct definition, so the caller gets the raw cdata and can use
    -- ffmpeg internals if needed. Pts/width/height are provided as nil
    -- on this fast path; richer accessors live in a future revision.
    return function()
        while true do
            local rc = cod.avcodec_receive_frame(cctx, frame)
            if rc == 0 then
                return { _frame = frame }
            end
            if rc ~= AVERROR_EAGAIN then
                cleanup(); return nil
            end
            -- Need a new packet.
            local rrc = fmtlib.av_read_frame(fc, pkt)
            if rrc == AVERROR_EOF or rrc < 0 then
                cod.avcodec_send_packet(cctx, nil)  -- flush
                local drc = cod.avcodec_receive_frame(cctx, frame)
                if drc == 0 then return { _frame = frame } end
                cleanup(); return nil
            end
            -- Send packet unconditionally; the decoder will ignore those
            -- whose stream doesn't match if we filtered earlier. Most
            -- callers will iterate a single stream-of-interest.
            cod.avcodec_send_packet(cctx, pkt)
            cod.av_packet_unref(pkt)
        end
    end, cleanup
end

-- ===== High-level operations via command-line ffmpeg ==================
--
-- For the heavyweight one-shot tasks (transcode, concat, cut, thumbnail
-- production) the libav* C API is verbose and version-fragile. When the
-- user has the bundled ffmpeg.exe available we shell out to it; that's
-- universally faster to keep correct across version bumps. When only the
-- DLLs are present we still expose probe/frames via the FFI.

local function shell_exe()
    -- Prefer LUAVM_FFMPEG_EXE; fall back to PATH.
    return os.getenv("LUAVM_FFMPEG_EXE") or "ffmpeg"
end

local function quote(s)
    if s:find('[%s"<>|&^%(%)]') then
        return '"' .. s:gsub('"', '\\"') .. '"'
    end
    return s
end

local function run_ffmpeg(args)
    local exe = shell_exe()
    local cmd = quote(exe) .. " -hide_banner -loglevel error"
    for _, a in ipairs(args) do cmd = cmd .. " " .. quote(a) end
    local ok, kind, code = os.execute(cmd)
    if ok == true or code == 0 then return true end
    if type(ok) == "number" and ok == 0 then return true end
    error("ffmpeg: command failed (" .. tostring(kind) .. " " .. tostring(code) .. "): " .. cmd)
end

local function exe_available()
    local exe = shell_exe()
    local f = io.popen(quote(exe) .. " -version 2>&1")
    if not f then return false end
    local out = f:read("*l") or ""
    f:close()
    return out:find("ffmpeg", 1, true) ~= nil
end

function M.convert(in_path, out_path, opts)
    opts = opts or {}
    if not exe_available() then
        error("ffmpeg.convert: ffmpeg.exe not on PATH (set LUAVM_FFMPEG_EXE)", 2)
    end
    local args = { "-y", "-i", in_path }
    if opts.video_codec   then args[#args + 1] = "-c:v"; args[#args + 1] = opts.video_codec end
    if opts.audio_codec   then args[#args + 1] = "-c:a"; args[#args + 1] = opts.audio_codec end
    if opts.video_bitrate then args[#args + 1] = "-b:v"; args[#args + 1] = tostring(opts.video_bitrate) end
    if opts.audio_bitrate then args[#args + 1] = "-b:a"; args[#args + 1] = tostring(opts.audio_bitrate) end
    if opts.scale then
        args[#args + 1] = "-vf"
        args[#args + 1] = string.format("scale=%d:%d", opts.scale.w or -1, opts.scale.h or -1)
    end
    if opts.fps          then args[#args + 1] = "-r"; args[#args + 1] = tostring(opts.fps) end
    if opts.extra        then for _, a in ipairs(opts.extra) do args[#args + 1] = a end end
    args[#args + 1] = out_path
    return run_ffmpeg(args)
end

function M.extract_audio(video_path, audio_path, opts)
    opts = opts or {}
    if not exe_available() then
        error("ffmpeg.extract_audio: ffmpeg.exe not on PATH", 2)
    end
    local args = { "-y", "-i", video_path, "-vn" }
    if opts.codec then
        args[#args + 1] = "-c:a"; args[#args + 1] = opts.codec
    else
        args[#args + 1] = "-c:a"; args[#args + 1] = "copy"
    end
    if opts.bitrate then args[#args + 1] = "-b:a"; args[#args + 1] = tostring(opts.bitrate) end
    args[#args + 1] = audio_path
    return run_ffmpeg(args)
end

function M.thumbnail(video_path, image_path, opts)
    opts = opts or {}
    if not exe_available() then
        error("ffmpeg.thumbnail: ffmpeg.exe not on PATH", 2)
    end
    local args = {
        "-y",
        "-ss", tostring(opts.time or 0),
        "-i",  video_path,
        "-frames:v", "1",
    }
    local w = opts.width  or 320
    local h = opts.height or -1
    args[#args + 1] = "-vf"
    args[#args + 1] = string.format("scale=%d:%d", w, h)
    args[#args + 1] = image_path
    return run_ffmpeg(args)
end

function M.cut(in_path, out_path, start_s, end_s)
    if not exe_available() then error("ffmpeg.cut: ffmpeg.exe not on PATH", 2) end
    local args = { "-y", "-ss", tostring(start_s), "-i", in_path }
    if end_s then
        args[#args + 1] = "-to"; args[#args + 1] = tostring(end_s)
    end
    args[#args + 1] = "-c"; args[#args + 1] = "copy"
    args[#args + 1] = out_path
    return run_ffmpeg(args)
end

function M.concat(in_paths, out_path, opts)
    opts = opts or {}
    if not exe_available() then error("ffmpeg.concat: ffmpeg.exe not on PATH", 2) end
    -- Build a temporary list-file consumable by the concat demuxer.
    local temp = (os.getenv("TEMP") or ".") .. "\\luavm_ffmpeg_concat_" .. tostring(os.time()) .. ".txt"
    local f, err = io.open(temp, "wb")
    if not f then error("ffmpeg.concat: cannot create list file: " .. tostring(err)) end
    for _, p in ipairs(in_paths) do
        -- The concat demuxer wants forward slashes & escaped quotes.
        f:write(string.format("file '%s'\n", (p:gsub("'", "'\\''"))))
    end
    f:close()
    local args = {
        "-y", "-f", "concat", "-safe", "0",
        "-i", temp,
        "-c", opts.recode and (opts.video_codec or "libx264") or "copy",
        out_path,
    }
    local ok, perr = pcall(run_ffmpeg, args)
    os.remove(temp)
    if not ok then error(perr) end
    return true
end

return M
