-- queue -- lock-free FIFO queues.
--
-- Public surface:
--   queue.mpmc(capacity)         -> bounded multi-producer / multi-consumer
--   queue.spsc(capacity)         -> bounded single-producer / single-consumer
--   queue.mpmc_unbounded()       -> unbounded multi-producer / multi-consumer
--
-- Methods (all variants):
--   :enqueue(value)              -> bool     true if accepted
--   :dequeue()                   -> value | nil      nil if empty
--   :try_enqueue(value)          -> bool     non-blocking alias
--   :try_dequeue()               -> value | nil      non-blocking alias
--   :size()                      -> approx int        unreliable under contention
--   :full()                      -> bool
--   :empty()                     -> bool
--   :capacity()                  -> int | math.huge
--   :close()                     marks queue dead; remaining items still drainable
--   :drain(handler?)             -> count             pulls everything; calls handler(v)
--
-- ===== Implementation =========================================
--
-- mpmc bounded: Vyukov ring buffer. Each slot carries a sequence counter
-- that producers and consumers compare-and-swap against the head / tail
-- indices. See https://www.1024cores.net/.../bounded-mpmc-queue
--
-- spsc bounded: classic single-producer / single-consumer ring. No CAS
-- needed (only one writer of head, one writer of tail). Slightly faster
-- under no contention because the producer path is just a comparison +
-- atomic-store + atomic-store-of-tail.
--
-- mpmc_unbounded: Michael-Scott linked list with sentinel. Each node is
-- a malloc + an atomic pointer to the next. Producers CAS tail->next;
-- consumers CAS head. Drains payloads via channel.serialize.
--
-- Values cross threads as channel-package serialized blobs. Same
-- supported-type set: nil, bool, int64, double, string, table.

local W      = require "windows"
local WT     = require "windows.threading"
local atomic = require "atomic"
local channel = require "channel"

local C = ffi.C
local M = {}

-- Lua 5.4 + FFI: stock parser, so 0LL isn't valid.
local I64_ZERO = ffi.cast("int64_t", 0)

ffi.cdef[[
typedef struct _q_slot {
    int64_t  seq;          /* sequence counter */
    void    *payload_ptr;  /* malloc'd serialized blob */
    int32_t  payload_len;
    int32_t  _pad;
} q_slot_t;

typedef struct _q_ring {
    int64_t           capacity;
    int64_t           mask;
    int64_t volatile  head;
    int64_t volatile  tail;
    int32_t volatile  closed;
    int32_t           _pad;
    q_slot_t         *slots;
} q_ring_t;

/* spsc-specific: separate cachelines for head / tail. We don't bother
   padding because Lua-level call overhead dwarfs any false-sharing
   savings; the layout is purely for clarity. */
typedef struct _q_spsc {
    int64_t           capacity;
    int64_t           mask;
    int64_t volatile  head;
    int64_t volatile  tail;
    int32_t volatile  closed;
    int32_t           _pad;
    q_slot_t         *slots;
} q_spsc_t;

/* unbounded linked list node */
typedef struct _q_node {
    struct _q_node * volatile next;
    void                     *payload_ptr;
    int32_t                   payload_len;
    int32_t                   _pad;
} q_node_t;

typedef struct _q_unbounded {
    q_node_t * volatile head;
    q_node_t * volatile tail;
    int32_t  volatile closed;
    int32_t  _pad;
    int64_t  volatile approx_size;
} q_unbounded_t;
]]

local function round_up_pow2(n)
    if n < 2 then return 2 end
    local v = n - 1
    v = v | (v >> 1)
    v = v | (v >> 2)
    v = v | (v >> 4)
    v = v | (v >> 8)
    v = v | (v >> 16)
    v = v | (v >> 32)
    return v + 1
end

-- ===== MPMC bounded =============================================

local mpmc_mt = { __index = {} }
local mpmc_methods = mpmc_mt.__index

local function destroy_mpmc(ring)
    if ring == nil or ring.slots == nil then return end
    local cap = tonumber(ring.capacity)
    for i = 0, cap - 1 do
        if ring.slots[i].payload_ptr ~= nil then
            C.free(ring.slots[i].payload_ptr)
            ring.slots[i].payload_ptr = nil
        end
    end
    C.free(ring.slots)
    ring.slots = nil
    C.free(ring)
end

function M.mpmc(capacity)
    if not capacity or capacity < 1 then
        error("queue.mpmc: capacity must be >= 1")
    end
    local cap = round_up_pow2(capacity)
    local ring = ffi.cast("q_ring_t *", C.malloc(ffi.sizeof("q_ring_t")))
    if ring == nil then error("queue.mpmc: malloc ring failed") end
    ring.capacity = cap
    ring.mask     = cap - 1
    ring.head     = 0
    ring.tail     = 0
    ring.closed   = 0
    ring.slots = ffi.cast("q_slot_t *",
        C.malloc(ffi.sizeof("q_slot_t") * cap))
    if ring.slots == nil then
        C.free(ring)
        error("queue.mpmc: malloc slots failed")
    end
    for i = 0, cap - 1 do
        ring.slots[i].seq         = i
        ring.slots[i].payload_ptr = nil
        ring.slots[i].payload_len = 0
    end
    -- Capture head / tail addresses up front: offsets 16 / 24 within the
    -- struct (two int64 prefix). Fragile against layout changes; keep the
    -- comment + the field order locked.
    local head_addr = ffi.cast("int64_t *", ring) + 2
    local tail_addr = ffi.cast("int64_t *", ring) + 3
    return setmetatable({
        ring      = ffi.gc(ring, destroy_mpmc),
        head_addr = head_addr,
        tail_addr = tail_addr,
        _kind     = "mpmc",
    }, mpmc_mt)
end

function mpmc_methods:capacity() return tonumber(self.ring.capacity) end

function mpmc_methods:size()
    local h = tonumber(self.ring.head)
    local t = tonumber(self.ring.tail)
    local n = t - h
    if n < 0 then n = 0 end
    if n > self:capacity() then n = self:capacity() end
    return n
end

function mpmc_methods:empty() return self:size() == 0 end
function mpmc_methods:full()  return self:size() >= self:capacity() end

function mpmc_methods:enqueue(value)
    if self.ring.closed ~= 0 then return false end
    local blob = channel.serialize(value)
    local blob_len = #blob
    local payload = C.malloc(blob_len)
    if payload == nil then error("queue.mpmc:enqueue: malloc payload failed") end
    ffi.copy(payload, blob, blob_len)

    local ring      = self.ring
    local tail_addr = self.tail_addr
    local mask      = tonumber(ring.mask)
    while true do
        local tail = C.InterlockedOr64(tail_addr, I64_ZERO)
        local tail_n = tonumber(tail)
        local slot = ring.slots + (tail_n & mask)
        local seq  = tonumber(slot.seq)
        local diff = seq - tail_n
        if diff == 0 then
            local cas = C.InterlockedCompareExchange64(tail_addr, tail_n + 1, tail_n)
            if tonumber(cas) == tail_n then
                slot.payload_ptr = payload
                slot.payload_len = blob_len
                slot.seq         = tail_n + 1
                return true
            end
        elseif diff < 0 then
            -- Full (slot belongs to previous cycle's consumer).
            C.free(payload)
            return false
        end
        -- diff > 0: another producer mid-publish. Spin.
    end
end

mpmc_methods.try_enqueue = mpmc_methods.enqueue

function mpmc_methods:dequeue()
    local ring      = self.ring
    local head_addr = self.head_addr
    local mask      = tonumber(ring.mask)
    while true do
        local head = C.InterlockedOr64(head_addr, I64_ZERO)
        local head_n = tonumber(head)
        local slot = ring.slots + (head_n & mask)
        local seq  = tonumber(slot.seq)
        local diff = seq - (head_n + 1)
        if diff == 0 then
            local cas = C.InterlockedCompareExchange64(head_addr, head_n + 1, head_n)
            if tonumber(cas) == head_n then
                local payload     = slot.payload_ptr
                local payload_len = slot.payload_len
                slot.payload_ptr = nil
                slot.payload_len = 0
                slot.seq         = head_n + tonumber(ring.capacity)
                local blob = ffi.string(payload, payload_len)
                C.free(payload)
                return channel.deserialize(blob)
            end
        elseif diff < 0 then
            return nil
        end
        -- diff > 0: a producer is mid-publish. Spin.
    end
end

mpmc_methods.try_dequeue = mpmc_methods.dequeue

function mpmc_methods:close() self.ring.closed = 1 end

function mpmc_methods:drain(handler)
    local n = 0
    while true do
        local v = self:dequeue()
        if v == nil then return n end
        n = n + 1
        if handler then handler(v) end
    end
end

-- ===== SPSC bounded =============================================
--
-- Single-producer / single-consumer ring. Only one thread writes tail;
-- only one thread writes head. No CAS needed for the index advances --
-- we just publish the slot, then store-release the tail. Reads use the
-- mirror pattern: read tail with acquire, copy payload, then advance
-- head with store.
--
-- The "release" / "acquire" pairing on x64 is naturally provided by
-- aligned 64-bit MOVs, but we still go through InterlockedExchange64
-- for the producer's tail-publish and consumer's head-publish so the
-- compiler is forced to emit a true memory barrier (LOCK XCHG).

local spsc_mt = { __index = {} }
local spsc_methods = spsc_mt.__index

function M.spsc(capacity)
    if not capacity or capacity < 1 then
        error("queue.spsc: capacity must be >= 1")
    end
    local cap = round_up_pow2(capacity)
    local ring = ffi.cast("q_spsc_t *", C.malloc(ffi.sizeof("q_spsc_t")))
    if ring == nil then error("queue.spsc: malloc ring failed") end
    ring.capacity = cap
    ring.mask     = cap - 1
    ring.head     = 0
    ring.tail     = 0
    ring.closed   = 0
    ring.slots = ffi.cast("q_slot_t *", C.malloc(ffi.sizeof("q_slot_t") * cap))
    if ring.slots == nil then C.free(ring); error("queue.spsc: malloc slots failed") end
    for i = 0, cap - 1 do
        ring.slots[i].seq         = 0
        ring.slots[i].payload_ptr = nil
        ring.slots[i].payload_len = 0
    end
    return setmetatable({
        ring  = ffi.gc(ring, destroy_mpmc),  -- same layout for payload cleanup
        _kind = "spsc",
    }, spsc_mt)
end

function spsc_methods:capacity() return tonumber(self.ring.capacity) end

function spsc_methods:size()
    local t = tonumber(self.ring.tail)
    local h = tonumber(self.ring.head)
    local n = t - h
    if n < 0 then n = 0 end
    if n > self:capacity() then n = self:capacity() end
    return n
end

function spsc_methods:empty() return self:size() == 0 end
function spsc_methods:full()  return self:size() >= self:capacity() end

function spsc_methods:enqueue(value)
    if self.ring.closed ~= 0 then return false end
    local ring = self.ring
    local mask = tonumber(ring.mask)
    local cap  = tonumber(ring.capacity)
    local tail = tonumber(ring.tail)
    local head = tonumber(ring.head)
    if tail - head >= cap then return false end
    local blob = channel.serialize(value)
    local blob_len = #blob
    local payload = C.malloc(blob_len)
    if payload == nil then error("queue.spsc:enqueue: malloc payload failed") end
    ffi.copy(payload, blob, blob_len)
    local slot = ring.slots + (tail & mask)
    slot.payload_ptr = payload
    slot.payload_len = blob_len
    -- Store-release of tail. Address of tail field is at offset 24.
    local tail_addr = ffi.cast("int64_t *", ring) + 3
    C.InterlockedExchange64(tail_addr, tail + 1)
    return true
end

spsc_methods.try_enqueue = spsc_methods.enqueue

function spsc_methods:dequeue()
    local ring = self.ring
    local mask = tonumber(ring.mask)
    local head = tonumber(ring.head)
    local tail = tonumber(ring.tail)
    if head == tail then return nil end
    local slot = ring.slots + (head & mask)
    local payload     = slot.payload_ptr
    local payload_len = slot.payload_len
    slot.payload_ptr = nil
    slot.payload_len = 0
    local blob = ffi.string(payload, payload_len)
    C.free(payload)
    -- Store-release of head. Address of head field is at offset 16.
    local head_addr = ffi.cast("int64_t *", ring) + 2
    C.InterlockedExchange64(head_addr, head + 1)
    return channel.deserialize(blob)
end

spsc_methods.try_dequeue = spsc_methods.dequeue

function spsc_methods:close() self.ring.closed = 1 end

function spsc_methods:drain(handler)
    local n = 0
    while true do
        local v = self:dequeue()
        if v == nil then return n end
        n = n + 1
        if handler then handler(v) end
    end
end

-- ===== MPMC unbounded ===========================================
--
-- Michael-Scott linked-list queue. The list always has a dummy sentinel
-- node at the head; head points at it; tail points at the last node.
-- Enqueue: malloc a new node, CAS tail->next from null to it, then CAS
-- tail to it. Dequeue: read head's next; CAS head to that next; the
-- payload of the next is returned (head is the new sentinel).

local unbounded_mt = { __index = {} }
local unbounded_methods = unbounded_mt.__index

local function destroy_unbounded(q)
    if q == nil then return end
    -- Walk and free all nodes (including the sentinel + any unconsumed
    -- payloads). The order is forward via next; safe because nothing
    -- else references the queue at gc time.
    local node = q.head
    while node ~= nil do
        local nxt = node.next
        if node.payload_ptr ~= nil then
            C.free(node.payload_ptr)
            node.payload_ptr = nil
        end
        C.free(node)
        node = nxt
    end
    q.head = nil
    q.tail = nil
    C.free(q)
end

local function new_node(payload_ptr, payload_len)
    local node = ffi.cast("q_node_t *", C.malloc(ffi.sizeof("q_node_t")))
    if node == nil then error("queue.mpmc_unbounded: malloc node failed") end
    node.next        = nil
    node.payload_ptr = payload_ptr
    node.payload_len = payload_len or 0
    return node
end

function M.mpmc_unbounded()
    local q = ffi.cast("q_unbounded_t *", C.malloc(ffi.sizeof("q_unbounded_t")))
    if q == nil then error("queue.mpmc_unbounded: malloc queue failed") end
    -- Sentinel node so producers / consumers never have to special-case
    -- empty: head and tail both point at the sentinel, and the "real"
    -- payload nodes are always head->next.
    local sentinel = new_node(nil, 0)
    q.head = sentinel
    q.tail = sentinel
    q.closed = 0
    q.approx_size = 0
    return setmetatable({
        q     = ffi.gc(q, destroy_unbounded),
        _kind = "unbounded",
    }, unbounded_mt)
end

function unbounded_methods:capacity() return math.huge end
function unbounded_methods:size()     return tonumber(self.q.approx_size) end
function unbounded_methods:empty()    return self:size() == 0 end
function unbounded_methods:full()     return false end

-- The address of q->tail and node->next fields, used for CAS on void**.
local function tail_ptr_addr(q)
    -- offset 8 in q_unbounded_t (after head pointer)
    return ffi.cast("void * *", ffi.cast("char *", q) + ffi.sizeof("void *"))
end

local function head_ptr_addr(q)
    return ffi.cast("void * *", q)  -- head is the first field
end

local function next_ptr_addr(node)
    return ffi.cast("void * *", node)  -- next is the first field
end

function unbounded_methods:enqueue(value)
    if self.q.closed ~= 0 then return false end
    local blob = channel.serialize(value)
    local blob_len = #blob
    local payload = C.malloc(blob_len)
    if payload == nil then error("queue.mpmc_unbounded: malloc payload failed") end
    ffi.copy(payload, blob, blob_len)
    local node = new_node(payload, blob_len)
    -- Michael-Scott enqueue: in a loop, read tail and tail->next.
    -- If tail->next is nil, CAS it to our new node; on success, CAS
    -- tail to our new node and return. If tail->next was non-nil,
    -- help the previous producer by CAS-advancing tail then retry.
    local q = self.q
    local tail_addr = tail_ptr_addr(q)
    while true do
        local tail = q.tail
        local next = tail.next
        if tail == q.tail then  -- consistent snapshot
            if next == nil then
                -- Try to publish our node as tail->next.
                local next_addr = next_ptr_addr(tail)
                local old = C.InterlockedCompareExchangePointer(
                                next_addr,
                                ffi.cast("void *", node),
                                nil)
                if old == nil then
                    -- Published. Advance tail (best-effort; other producers
                    -- will help if our CAS fails).
                    C.InterlockedCompareExchangePointer(
                        tail_addr,
                        ffi.cast("void *", node),
                        ffi.cast("void *", tail))
                    C.InterlockedIncrement64(
                        ffi.cast("int64_t *", ffi.cast("char *", q)
                                 + 2 * ffi.sizeof("void *") + 8))
                    return true
                end
            else
                -- Tail lagging: help advance it.
                C.InterlockedCompareExchangePointer(
                    tail_addr,
                    ffi.cast("void *", next),
                    ffi.cast("void *", tail))
            end
        end
    end
end

unbounded_methods.try_enqueue = unbounded_methods.enqueue

function unbounded_methods:dequeue()
    local q = self.q
    local head_addr = head_ptr_addr(q)
    local tail_addr = tail_ptr_addr(q)
    while true do
        local head = q.head
        local tail = q.tail
        local next = head.next
        if head == q.head then
            if head == tail then
                if next == nil then return nil end  -- empty
                -- Tail lagging; help advance it.
                C.InterlockedCompareExchangePointer(
                    tail_addr,
                    ffi.cast("void *", next),
                    ffi.cast("void *", tail))
            else
                if next == nil then
                    -- Inconsistent snapshot; retry.
                else
                    -- Read payload BEFORE the CAS; if we lose the race
                    -- the values we read are still valid for our own
                    -- copy purposes (no one else can have freed the
                    -- payload yet -- they're still chasing the head CAS).
                    local payload     = next.payload_ptr
                    local payload_len = next.payload_len
                    local old = C.InterlockedCompareExchangePointer(
                                    head_addr,
                                    ffi.cast("void *", next),
                                    ffi.cast("void *", head))
                    if old == ffi.cast("void *", head) then
                        -- We won. `head` is now garbage (was the sentinel);
                        -- `next` is the new sentinel; its payload is ours.
                        local blob = ffi.string(payload, payload_len)
                        C.free(payload)
                        -- Free the OLD sentinel.
                        C.free(head)
                        C.InterlockedDecrement64(
                            ffi.cast("int64_t *", ffi.cast("char *", q)
                                     + 2 * ffi.sizeof("void *") + 8))
                        return channel.deserialize(blob)
                    end
                end
            end
        end
    end
end

unbounded_methods.try_dequeue = unbounded_methods.dequeue

function unbounded_methods:close() self.q.closed = 1 end

function unbounded_methods:drain(handler)
    local n = 0
    while true do
        local v = self:dequeue()
        if v == nil then return n end
        n = n + 1
        if handler then handler(v) end
    end
end

return M
