-- AOT differential: table constructors — SETLIST in its several forms.
--   * small array literal (single SETLIST, no EXTRAARG)
--   * mixed array + hash + explicit integer key
--   * large array literal (> MAXARG_C) forcing the SETLIST/NEWTABLE EXTRAARG
--     size/index fusion
--   * multret tail (SETLIST B==0: count taken from L->top)

-- small array constructor
local t = { 10, 20, 30, 40 }
print("array", t[1], t[2], t[3], t[4], #t)

-- mixed constructor: array part + hash field + explicit integer key
local mx = { 1, 2, x = 3, [10] = 4 }
print("mixed", mx[1], mx[2], mx.x, mx[10])

-- large array literal: 600 elements > MAXARG_C(511), exercising the EXTRAARG
-- high-bits fusion for both NEWTABLE's array-size hint and SETLIST's start index
local big = {
  1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,
}
for i = 21, 600 do big[i] = i end
local bs = 0
for i = 1, #big do bs = bs + big[i] end
print("big", #big, bs, big[1], big[300], big[600])

-- multret tail: last constructor element is a multi-return call, so the
-- compiler emits SETLIST with B==0 (count read from L->top at runtime)
local mr = { 10, string.byte("ABC", 1, 3) }
print("multret", mr[1], mr[2], mr[3], mr[4], #mr)
