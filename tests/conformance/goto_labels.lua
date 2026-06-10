-- goto_labels.lua : forward/backward goto, loop-continue idiom, jumping out of
-- nested blocks, goto to end of block. Deterministic; JIT and -i must agree.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end

-- forward goto: skip a statement
do
  local out = {}
  out[#out+1] = "a"
  goto skip
  out[#out+1] = "SKIPPED"
  ::skip::
  out[#out+1] = "b"
  show(table.concat(out, ","))                 -- a,b
end

-- backward goto: a manual loop
do
  local i = 0
  local out = {}
  ::top::
  i = i + 1
  out[#out+1] = i
  if i < 5 then goto top end
  show(table.concat(out, ","))                 -- 1,2,3,4,5
end

-- "continue" idiom: goto a label at the end of the loop body
do
  local out = {}
  for i = 1, 10 do
    if i % 2 == 0 then goto cont end
    out[#out+1] = i
    ::cont::
  end
  show(table.concat(out, ","))                 -- 1,3,5,7,9
end

-- nested loop break-out via goto to an outer label
do
  local found
  for i = 1, 5 do
    for j = 1, 5 do
      if i * j == 12 then found = i .. "x" .. j; goto done end
    end
  end
  ::done::
  show(found)                                  -- 3x4
end

-- goto skipping forward over a block, label after the block
do
  local log = {}
  for i = 1, 3 do
    log[#log+1] = "iter" .. i
    if i == 2 then goto next end
    log[#log+1] = "body" .. i
    ::next::
  end
  show(table.concat(log, ","))                 -- iter1,body1,iter2,iter3,body3
end

-- goto into a label at the very end of a function (implicit return after)
do
  local function classify(n)
    if n < 0 then goto neg end
    if n == 0 then goto zero end
    do return "positive" end
    ::neg:: do return "negative" end
    ::zero:: do return "zero" end
  end
  show(classify(-5), classify(0), classify(7))  -- negative zero positive
end

-- goto across a while with state accumulation (state machine)
do
  local state = "start"
  local steps = {}
  ::loop::
  steps[#steps+1] = state
  if state == "start" then state = "middle"; goto loop end
  if state == "middle" then state = "end"; goto loop end
  -- state == "end": stop
  show(table.concat(steps, "->"))               -- start->middle->end
end

-- multiple labels, jump to the correct one based on a value
do
  local function route(x)
    if x == 1 then goto one elseif x == 2 then goto two else goto other end
    ::one:: do return "ONE" end
    ::two:: do return "TWO" end
    ::other:: do return "OTHER" end
  end
  show(route(1), route(2), route(3))            -- ONE TWO OTHER
end
