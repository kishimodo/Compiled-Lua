-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- serial -- Windows serial port (COM) I/O.
--
-- Public surface:
--   serial.list()                              -> { { name, friendly_name }, ... }
--   serial.open(port_name, opts?)              -> port
--
--   opts = {
--       baud=9600, data_bits=8, stop_bits=1,
--       parity="none"|"even"|"odd"|"mark"|"space",
--       flow_control="none"|"hardware"|"software",
--       read_timeout_ms=1000, write_timeout_ms=1000,
--       dtr=true, rts=true,
--   }
--
-- port methods:
--   :read(n, timeout_ms?)  -> bytes (string) | nil, "timeout"
--   :write(bytes)          -> nbytes_written
--   :read_line(eol?)       -> string (without eol) | nil
--   :available()           -> int (bytes pending in input queue)
--   :flush()               -> clears the input + output queues
--   :drain()               -> blocks until output is fully sent
--   :set_baud(n)
--   :set_break(on)
--   :set_dtr(on)
--   :set_rts(on)
--   :get_signals()         -> { cts, dsr, ring, dcd }
--   :close()

local W = require "windows"

ffi.cdef[[
typedef struct _DCB {
    DWORD  DCBlength;
    DWORD  BaudRate;
    DWORD  fBitfield;
    WORD   wReserved;
    WORD   XonLim;
    WORD   XoffLim;
    BYTE   ByteSize;
    BYTE   Parity;
    BYTE   StopBits;
    BYTE   XonChar;
    BYTE   XoffChar;
    BYTE   ErrorChar;
    BYTE   EofChar;
    BYTE   EvtChar;
    WORD   wReserved1;
} DCB;

typedef struct _COMMTIMEOUTS {
    DWORD ReadIntervalTimeout;
    DWORD ReadTotalTimeoutMultiplier;
    DWORD ReadTotalTimeoutConstant;
    DWORD WriteTotalTimeoutMultiplier;
    DWORD WriteTotalTimeoutConstant;
} COMMTIMEOUTS;

typedef struct _COMSTAT {
    DWORD fBitfield;
    DWORD cbInQue;
    DWORD cbOutQue;
} COMSTAT;

BOOL SetCommState(HANDLE, DCB *);
BOOL GetCommState(HANDLE, DCB *);
BOOL SetCommTimeouts(HANDLE, COMMTIMEOUTS *);
BOOL GetCommTimeouts(HANDLE, COMMTIMEOUTS *);
BOOL SetupComm(HANDLE, DWORD, DWORD);
BOOL PurgeComm(HANDLE, DWORD);
BOOL ClearCommError(HANDLE, DWORD *, COMSTAT *);
BOOL FlushFileBuffers(HANDLE);
BOOL EscapeCommFunction(HANDLE, DWORD);
BOOL GetCommModemStatus(HANDLE, DWORD *);
]]

local C = ffi.C
local M = {}

-- ===== constants ==========================================================

local NOPARITY    = 0
local ODDPARITY   = 1
local EVENPARITY  = 2
local MARKPARITY  = 3
local SPACEPARITY = 4
local PARITY_MAP  = {
    none = NOPARITY,  odd = ODDPARITY,  even = EVENPARITY,
    mark = MARKPARITY, space = SPACEPARITY,
}

local ONESTOPBIT   = 0
local ONE5STOPBITS = 1
local TWOSTOPBITS  = 2

-- EscapeCommFunction codes
local SETXOFF  = 1
local SETXON   = 2
local SETRTS   = 3
local CLRRTS   = 4
local SETDTR   = 5
local CLRDTR   = 6
local SETBREAK = 8
local CLRBREAK = 9

-- PurgeComm flags
local PURGE_RXABORT = 0x02
local PURGE_RXCLEAR = 0x08
local PURGE_TXABORT = 0x01
local PURGE_TXCLEAR = 0x04

-- GetCommModemStatus mask bits
local MS_CTS_ON  = 0x10
local MS_DSR_ON  = 0x20
local MS_RING_ON = 0x40
local MS_RLSD_ON = 0x80

local GENERIC_READ  = 0x80000000
local GENERIC_WRITE = 0x40000000
local OPEN_EXISTING = 3
local FILE_ATTRIBUTE_NORMAL = 0x80

-- ===== DCB helpers ========================================================
--
-- DCB has a packed bitfield right after BaudRate. We model it as a single
-- DWORD and toggle bits explicitly so callers don't have to think about
-- field ordering / bit positions.

local DCB_FBINARY            = 0x00000001
local DCB_FPARITY            = 0x00000002
local DCB_FOUTXCTSFLOW       = 0x00000004
local DCB_FOUTXDSRFLOW       = 0x00000008
local DCB_FDTRCONTROL_MASK   = 0x00000030
local DCB_FDTRCONTROL_ENABLE = 0x00000010
local DCB_FDTRCONTROL_HSHK   = 0x00000020
local DCB_FOUTX              = 0x00000100
local DCB_FINX               = 0x00000200
local DCB_FRTSCONTROL_MASK   = 0x00003000
local DCB_FRTSCONTROL_ENABLE = 0x00001000
local DCB_FRTSCONTROL_HSHK   = 0x00002000

-- ===== list() =============================================================
--
-- Ports live under HKLM\HARDWARE\DEVICEMAP\SERIALCOMM as value entries
-- whose data is the COM port name and whose name is the friendly identifier
-- (e.g. \Device\Serial0 -> COM1).

local function list_from_registry()
    local out = {}
    local hkey = ffi.new("HKEY[1]")
    local r = C.RegOpenKeyExW(W.HKEY_LOCAL_MACHINE,
        W.ToWide("HARDWARE\\DEVICEMAP\\SERIALCOMM"), 0, W.KEY_READ, hkey)
    if r ~= 0 then return out end
    local idx = 0
    while true do
        local name = ffi.new("unsigned short[256]")
        local name_sz = ffi.new("DWORD[1]", 256)
        local val_type = ffi.new("DWORD[1]")
        local val = ffi.new("BYTE[512]")
        local val_sz = ffi.new("DWORD[1]", 512)
        local r2 = ffi.C.RegEnumValueW(hkey[0], idx, name, name_sz,
            nil, val_type, val, val_sz)
        if r2 ~= 0 then break end
        local friendly = W.FromWide(name)
        local port     = W.FromWide(ffi.cast("unsigned short *", val))
        out[#out + 1] = { name = port, friendly_name = friendly }
        idx = idx + 1
    end
    C.RegCloseKey(hkey[0])
    return out
end

ffi.cdef[[
LSTATUS RegEnumValueW(HKEY hKey, DWORD dwIndex, LPWSTR lpValueName,
    DWORD *lpcchValueName, DWORD *lpReserved, DWORD *lpType,
    BYTE *lpData, DWORD *lpcbData);
]]

function M.list()
    return list_from_registry()
end

-- ===== open() =============================================================

local port_mt = { __index = {} }
local pm = port_mt.__index

local function build_path(name)
    -- COM10+ requires the \\.\ prefix; harmless for COM1..9 too.
    return "\\\\.\\" .. name
end

local function configure(handle, opts)
    local dcb = ffi.new("DCB[1]")
    dcb[0].DCBlength = ffi.sizeof("DCB")
    if C.GetCommState(handle, dcb) == 0 then
        error("serial: GetCommState failed")
    end
    dcb[0].BaudRate = opts.baud or 9600
    dcb[0].ByteSize = opts.data_bits or 8
    dcb[0].Parity   = PARITY_MAP[opts.parity or "none"] or NOPARITY
    local sb = opts.stop_bits or 1
    if sb == 1 then dcb[0].StopBits = ONESTOPBIT
    elseif sb == 1.5 then dcb[0].StopBits = ONE5STOPBITS
    elseif sb == 2 then dcb[0].StopBits = TWOSTOPBITS
    else error("serial: bad stop_bits " .. tostring(sb)) end

    -- Build the bitfield from scratch.
    local bits = DCB_FBINARY
    if dcb[0].Parity ~= NOPARITY then
        bits = bit.bor(bits, DCB_FPARITY)
    end

    -- DTR / RTS initial state. (Caller can flip later via set_dtr / set_rts.)
    if opts.dtr ~= false then bits = bit.bor(bits, DCB_FDTRCONTROL_ENABLE) end
    if opts.rts ~= false then bits = bit.bor(bits, DCB_FRTSCONTROL_ENABLE) end

    local fc = opts.flow_control or "none"
    if fc == "hardware" then
        bits = bit.band(bits, bit.bnot(DCB_FRTSCONTROL_MASK))
        bits = bit.bor(bits, DCB_FRTSCONTROL_HSHK, DCB_FOUTXCTSFLOW)
    elseif fc == "software" then
        bits = bit.bor(bits, DCB_FOUTX, DCB_FINX)
        dcb[0].XonChar  = 17  -- ^Q
        dcb[0].XoffChar = 19  -- ^S
        dcb[0].XonLim   = 2048
        dcb[0].XoffLim  = 512
    end

    dcb[0].fBitfield = bits

    if C.SetCommState(handle, dcb) == 0 then
        error("serial: SetCommState failed")
    end

    -- Set timeouts. We use the documented "blocking read until n bytes or
    -- ReadTotalTimeoutConstant ms" pattern.
    local to = ffi.new("COMMTIMEOUTS[1]")
    to[0].ReadIntervalTimeout         = 50
    to[0].ReadTotalTimeoutMultiplier  = 10
    to[0].ReadTotalTimeoutConstant    = opts.read_timeout_ms or 1000
    to[0].WriteTotalTimeoutMultiplier = 10
    to[0].WriteTotalTimeoutConstant   = opts.write_timeout_ms or 1000
    if C.SetCommTimeouts(handle, to) == 0 then
        error("serial: SetCommTimeouts failed")
    end

    -- Reasonable in / out buffer sizes.
    C.SetupComm(handle, 4096, 4096)
end

function M.open(name, opts)
    opts = opts or {}
    local path = build_path(name)
    local h = C.CreateFileW(W.ToWide(path),
        bit.bor(GENERIC_READ, GENERIC_WRITE), 0, nil,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nil)
    if h == W.INVALID_HANDLE_VALUE then
        error("serial: failed to open " .. name)
    end
    configure(h, opts)
    return setmetatable({
        _h           = h,
        _name        = name,
        _read_to_ms  = opts.read_timeout_ms or 1000,
        _write_to_ms = opts.write_timeout_ms or 1000,
        _baud        = opts.baud or 9600,
    }, port_mt)
end

-- ===== read / write =======================================================

function pm:write(s)
    if type(s) ~= "string" then s = tostring(s) end
    local n = #s
    local sent = ffi.new("DWORD[1]")
    if C.WriteFile(self._h, s, n, sent, nil) == 0 then
        return nil, "write failed"
    end
    return tonumber(sent[0])
end

local function set_read_timeout(self, ms)
    local to = ffi.new("COMMTIMEOUTS[1]")
    to[0].ReadIntervalTimeout         = 50
    to[0].ReadTotalTimeoutMultiplier  = 10
    to[0].ReadTotalTimeoutConstant    = ms
    to[0].WriteTotalTimeoutMultiplier = 10
    to[0].WriteTotalTimeoutConstant   = self._write_to_ms
    C.SetCommTimeouts(self._h, to)
    self._read_to_ms = ms
end

function pm:read(n, timeout_ms)
    if timeout_ms and timeout_ms ~= self._read_to_ms then
        set_read_timeout(self, timeout_ms)
    end
    local buf = ffi.new("char[?]", n)
    local got = ffi.new("DWORD[1]")
    if C.ReadFile(self._h, buf, n, got, nil) == 0 then
        return nil, "read failed"
    end
    if got[0] == 0 then return nil, "timeout" end
    return ffi.string(buf, got[0])
end

function pm:available()
    local errs = ffi.new("DWORD[1]")
    local cs   = ffi.new("COMSTAT[1]")
    if C.ClearCommError(self._h, errs, cs) == 0 then return 0 end
    return tonumber(cs[0].cbInQue)
end

function pm:read_line(eol)
    eol = eol or "\n"
    local first = eol:sub(1, 1):byte()
    local parts = {}
    local b = ffi.new("char[1]")
    local got = ffi.new("DWORD[1]")
    while true do
        if C.ReadFile(self._h, b, 1, got, nil) == 0 or got[0] == 0 then
            if #parts == 0 then return nil, "timeout" end
            return table.concat(parts)
        end
        local ch = b[0]
        if ch == first then
            -- Check multi-byte eol.
            if #eol == 1 then return table.concat(parts) end
            local matched = true
            for j = 2, #eol do
                if C.ReadFile(self._h, b, 1, got, nil) == 0 or got[0] == 0 or
                   b[0] ~= eol:sub(j, j):byte() then
                    matched = false; break
                end
            end
            if matched then return table.concat(parts) end
        else
            parts[#parts + 1] = string.char(ch)
        end
    end
end

function pm:flush()
    C.PurgeComm(self._h, bit.bor(PURGE_RXCLEAR, PURGE_TXCLEAR,
        PURGE_RXABORT, PURGE_TXABORT))
end

function pm:drain()
    C.FlushFileBuffers(self._h)
end

function pm:set_baud(n)
    local dcb = ffi.new("DCB[1]")
    dcb[0].DCBlength = ffi.sizeof("DCB")
    if C.GetCommState(self._h, dcb) == 0 then
        error("serial: GetCommState failed")
    end
    dcb[0].BaudRate = n
    if C.SetCommState(self._h, dcb) == 0 then
        error("serial: SetCommState(baud) failed")
    end
    self._baud = n
end

function pm:set_break(on)
    C.EscapeCommFunction(self._h, on and SETBREAK or CLRBREAK)
end

function pm:set_dtr(on)
    C.EscapeCommFunction(self._h, on and SETDTR or CLRDTR)
end

function pm:set_rts(on)
    C.EscapeCommFunction(self._h, on and SETRTS or CLRRTS)
end

function pm:get_signals()
    local mask = ffi.new("DWORD[1]")
    if C.GetCommModemStatus(self._h, mask) == 0 then
        return { cts = false, dsr = false, ring = false, dcd = false }
    end
    local v = tonumber(mask[0])
    return {
        cts  = bit.band(v, MS_CTS_ON) ~= 0,
        dsr  = bit.band(v, MS_DSR_ON) ~= 0,
        ring = bit.band(v, MS_RING_ON) ~= 0,
        dcd  = bit.band(v, MS_RLSD_ON) ~= 0,
    }
end

function pm:close()
    if self._h and self._h ~= W.INVALID_HANDLE_VALUE then
        C.CloseHandle(self._h)
        self._h = nil
    end
end

port_mt.__gc = pm.close

return M
