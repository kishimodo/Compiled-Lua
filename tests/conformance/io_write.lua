-- io.write determinism: io.write coerces numbers like tostring-for-output but
-- WITHOUT a trailing newline or tab separators, accepts multiple arguments, and
-- returns the file (so calls chain). Must match the interpreter byte-for-byte.

-- multiple arguments, no separators or newline
io.write("a", "b", "c")
io.write("\n")

-- numbers: integers print without a decimal point, floats with %.14g
io.write(42, " ", 3.5, " ", -7, " ", 1/2, "\n")
io.write(100, 200, 300, "\n")                 -- 100200300

-- integer vs float formatting parity with tostring
io.write(tostring(10), "=", 10, " ", tostring(10.0), "=", 10.0, "\n")

-- io.write returns the file -> chaining
io.write("x"):write("y"):write("z")
io.write("\n")

-- large/edge numbers
io.write(math.maxinteger, "\n")
io.write(math.pi, "\n")
io.write(1e100, " ", 1e-100, "\n")
io.write(-0.0, " ", 1/0, " ", -1/0, "\n")

-- write a built-up string and a numeric loop, no trailing newline issues
do
  for i = 1, 5 do io.write(i) end
  io.write("\n")
end

-- print uses tabs + newline; contrast it with io.write of the same values
print(1, 2, 3)
io.write(1, "\t", 2, "\t", 3, "\n")

print("[+] PASS io_write")
