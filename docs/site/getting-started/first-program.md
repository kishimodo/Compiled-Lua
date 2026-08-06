# first program

this page walks through compiling and running a hello world with clua. it
assumes you finished the install page and `clua version` prints something
sensible.

## write hello.lua

put this in a file named `hello.lua`:

```lua
print("hello from clua")
```

## compile it

from the same directory, run:

```
clua build hello.lua
```

that produces `hello.exe` in the current directory. the output name comes
from the input file with the `.lua` extension replaced by `.exe`. pass
`-o some\other\path.exe` if you want to control the destination.

the compiler prints a short banner as it runs. a successful build exits
with status zero and leaves the exe next to your source.

## run it

```
hello.exe
```

that prints `hello from clua` to stdout, then exits. the binary is standalone:
you can copy it to a machine that has no clua toolchain installed and it will
still run, as long as the target machine is windows x64 with a recent enough
crt.

## compile and run in one step

for iteration, `clua run` is faster because it compiles to a temporary
location and executes in place without leaving an exe behind:

```
clua run hello.lua
```

pass program arguments after a lone `--`:

```
clua run hello.lua -- one two three
```

everything before `--` is a clua flag, everything after is passed to the
program as `arg[1]`, `arg[2]`, and so on.

## just check the source

if you want to know whether a program parses and passes the closed-world
gate, without actually building an exe:

```
clua check hello.lua
```

this runs the front end and the closed-world check, then exits. it is much
faster than a full build and is what an editor plugin would call on save.
