# Native code

A Mettle program calls C through `extern fn` declarations. mbuild provides
the other half: it compiles C sources, finds libraries, passes the right link
arguments to the compiler for each target, and puts the shared libraries the
program needs beside the binary. It does this for every package in the
dependency graph, so a package that wraps a C library works in any project
that imports it.

How `extern` declarations, `cstring`, `rawptr` and structs cross the boundary
is Mettle's business: see
[C interoperability](https://github.com/suidvandiewereld/Mettle/blob/main/docs/c-interop.md)
and [Shared libraries](https://github.com/suidvandiewereld/Mettle/blob/main/docs/shared-libraries.md).

## Two kinds of native code

| Calls | For |
|---|---|
| `mb_c_sources`, `mb_c_include`, `mb_c_flags`, `mb_c_libs` | C source files that belong to the package. mbuild compiles them into one shared library per package. |
| `mb_link_libs`, `mb_link_paths`, `mb_pkgconfig` | Libraries that already exist: system libraries, pkg-config packages, prebuilt `.so` and `.dll` files shipped in the package. |

Each takes a comma-separated list. After `mb_on("linux")` or
`mb_on("windows")` they add to that target only, until `mb_on("")`.

## C sources

The fixture package `vecmath` wraps three C functions:

```mettle
// mbuild.mettle
import "mbuild/api";

fn project() {
  mb_package("vecmath", "0.4.0");
  mb_c_sources("csrc");
  mb_c_include("csrc/include");
  mb_c_flags("-O2");
  mb_on("linux");
  mb_c_libs("m");
  mb_on("");
}
```

```c
// csrc/vec.c
#include <math.h>
#include "vec.h"
float vm_dot(Vec2 a, Vec2 b) { return a.x * b.x + a.y * b.y; }
float vm_len(Vec2 a) { return sqrtf(vm_dot(a, a)); }
Vec2 vm_scale(Vec2 a, float k) { Vec2 r = { a.x * k, a.y * k }; return r; }
```

```mettle
// vecmath.mettle
export struct Vec2 {
  x: float32;
  y: float32;
}

export extern fn vm_dot(a: Vec2, b: Vec2) -> float32 = "vm_dot";
export extern fn vm_len(a: Vec2) -> float32 = "vm_len";
export extern fn vm_scale(a: Vec2, k: float32) -> Vec2 = "vm_scale";
```

A project that imports `vecmath/vecmath` gets it built for each target with
nothing about C in its own `mbuild.mettle`:

```text
$ mbuild -v build --force
...
   Compiling vecmath (C, 1 file)
  > /bin/cc -c /home/you/vm/.mbuild/deps/vecmath/csrc/vec.c -o /home/you/vm/.mbuild/cache/linux/c/vecmath/csrc/vec.c.o -MMD -MF /home/you/vm/.mbuild/cache/linux/c/vecmath/csrc/vec.c.o.d -fPIC -I /home/you/vm/.mbuild/deps/vecmath/csrc/include -O2
  > /bin/cc -shared -o /home/you/vm/.mbuild/cache/linux/lib/libmb_vecmath.so /home/you/vm/.mbuild/cache/linux/c/vecmath/csrc/vec.c.o -Wl,-soname,libmb_vecmath.so -Wl,-Bsymbolic -lm
   Compiling vm (linux, debug)
  > NO_COLOR=1 /home/you/Mettle/bin/mettle -s -I .mbuild/deps -L/home/you/vm/.mbuild/cache/linux/lib -lmb_vecmath --rpath '$ORIGIN' --build src/main.mettle -o build/linux/debug/vm
Built executable 'build/linux/debug/vm'
    Finished in 0.0s
$ ls build/linux/debug
libmb_vecmath.so
vm
```

What happens, per package with C sources:

1. Each source is compiled to an object under
   `.mbuild/cache/<target>/c/<package>/`, with a depfile that records the
   headers it included. Linux objects add `-fPIC`. Files compile in parallel
   (`-j N`, `MBUILD_JOBS`, default 8).
2. The objects are linked into one shared library: `libmb_<package>.so` on
   Linux, `mb_<package>.dll` on Windows. `mb_c_libs` are the libraries this C
   code itself needs (`-lm` above). Windows DLLs add `-static-libgcc`, so they
   don't need MinGW's libgcc DLL.
3. The program's link names every such library, and the library is copied
   beside the binary.

The libraries go on the link with dependents before their dependencies.

### C code that calls C code in a dependency

A package's C may call the C of the packages it depends on. mbuild builds
dependencies first, compiles with `-I` for every dependency's include
directories (after the package's own), and links the package's library
against its dependencies' libraries (on Linux with `-Wl,-rpath,$ORIGIN`, so
they're found beside the binary) and their `mb_link_libs`. A change to a
dependency's header recompiles the objects that include it.

### C flags per profile

`cflags` in a profile of your project are added to every package's C flags
(yours and your dependencies') in that profile. No profile adds C flags by
default, not even `release`:

```mettle
  mb_profile("release");
  mb_set_list("cflags", "-O2");
```

A profile with `cflags` keeps its objects and libraries apart
(`.mbuild/cache/<target>/c-release/`, `lib-release/`), so switching between
debug and release doesn't recompile anything twice. A dependency's own
profiles are ignored.

## Existing libraries

### System libraries and pkg-config

```mettle
  mb_on("linux");
  mb_link_libs("z");          // or: mb_pkgconfig("zlib");
  mb_on("windows");
  mb_link_libs("zlib1");
  mb_on("");
```

```mettle
import "std/io";

extern fn deflate_bound(n: int64) -> int64 = "compressBound";

fn main() -> int32 {
  println("bound={deflate_bound(100)}");
  return 0;
}
```

```text
$ mbuild run
   Compiling lk (linux, debug)
    Finished in 0.0s
     Running build/linux/debug/lk
bound=113
```

Each `mb_pkgconfig` name runs `pkg-config --libs NAME`, and its `-L` and `-l`
words go to the link. For the Linux target the program is `$PKG_CONFIG`, else
`pkg-config`. For the Windows target it is `$PKG_CONFIG_WINDOWS`, else
`x86_64-w64-mingw32-pkg-config`; its `-l` names become DLL imports, and its
`-L` directories (and the `bin/` beside each, where MinGW keeps DLLs) go on
the DLL search path of the compile. Without either, a `pkgconfig` entry is
skipped for Windows with a warning: name the DLL with `mb_link_libs` instead.

The Mettle linker records only the libraries a symbol actually comes from,
so a library nothing uses doesn't end up in the binary.

### Prebuilt libraries in the package

```mettle
  mb_link_libs("vend");
  mb_link_paths("vendor/lib");
```

Paths are relative to the package. A library in `mb_link_libs` that is found
in one of them (`libvend.so` and its versioned names on Linux, `vend.dll` on
Windows) is copied beside the binary:

```text
$ mbuild run
   Compiling vend (linux, debug)
    Finished in 0.0s
     Running build/linux/debug/vend
answer 42
$ ls build/linux/debug
libvend.so
vend
$ readelf -d build/linux/debug/vend | grep -i 'needed\|runpath'
 0x0000000000000001 (NEEDED)             Shared library: [libvend.so]
 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN]
```

Ship one directory per target and the program finds its libraries.

## What happens on each OS

### Linux

- Every library becomes `-l<name>`, every library directory `-L<dir>`.
- When anything is linked, mbuild adds `--rpath $ORIGIN`, so the program looks
  for libraries in its own directory first.
- C libraries and libraries found in `mb_link_paths` are copied beside the
  binary. System libraries aren't: the machine that runs the program needs
  them installed.

### Windows

- Every library becomes `--link-arg -l<name>`, which imports `<name>.dll`.
- The Windows compiler checks each DLL by loading it, so mbuild puts every
  library directory in front of `PATH` (on Windows) or `WINEPATH` (Linux
  mbuild running the Windows compiler through wine) for that one compile.
- C DLLs and DLLs found in `mb_link_paths` are copied beside the `.exe`,
  where Windows looks first. DLLs found only on `PATH` or in `system32` are
  not.
- `kernel32`, `user32`, `gdi32`, `advapi32` and `ws2_32` need no
  `mb_link_libs`.

## C compilers

| Target | mbuild uses the first of |
|---|---|
| Linux | `$CC`; `mb_tool("cc", ...)`; `cc`; `gcc`; `clang` |
| Windows | `$CC_WINDOWS`; `mb_tool("cc-windows", ...)`; `x86_64-w64-mingw32-gcc`; on a Windows host, `gcc` or `clang` |

On Linux, C code for the Windows target needs MinGW-w64
(`sudo apt install gcc-mingw-w64-x86-64` on Debian and Ubuntu). A real
Windows host can't compile C for Linux. A C compiler is only looked for when
some package has C sources.

## When the link fails

The compiler's linker stops at the first unresolved symbol. mbuild then
checks every other `extern` in the project and its dependencies, searches
the system's libraries for each missing name, and says where each one was
declared, which library defines it, and what to link. Double-precision libm
names (`cos`, `sqrt`, ...) get a note to use `std/math` instead. The Windows
C runtime DLLs (`msvcrt`, `ucrtbase`, ...) are never suggested, because the
Mettle linker refuses them.

A library you named that isn't installed:

```text
$ mbuild build
   Compiling lk (linux, debug)
Error: Could not find shared library 'libnosuch.so' for -lnosuch on the library search path
Error: The internal ELF linker could not produce 'build/linux/debug/lk'
error: library `nosuch` (from mbuild.mettle ([link] libs of lk)) is not installed: no libnosuch.so on the library search path
  help: install its development package (it provides libnosuch.so), or put the directory holding it under [link] paths
error: could not compile lk (linux, debug)
```

(`[link] libs` is `mb_link_libs`, `[link] paths` is `mb_link_paths`.)

## mbuild doctor

`mbuild doctor` runs the same search on demand, for every `extern` of the
project and its dependencies, per target:

```text
$ mbuild doctor
mbuild 0.2.0
  host      linux
  project   vm (.)
  home      /home/you/.mbuild
tools
  curl        found  /bin/curl
  tar         found  /bin/tar
  cc          found  /bin/cc
  cc windows  found  /bin/x86_64-w64-mingw32-gcc
  pkg-config  found  /bin/pkg-config
  wine        found  /bin/wine
compilers
  linux     /home/you/Mettle/bin/mettle (v0.17.0; $METTLE)
            stdlib /home/you/Mettle/stdlib
native
  linux: 3 externs
    vm_dot    .mbuild/deps/vecmath/vecmath.mettle:8   C library libmb_vecmath.so (vecmath)
    vm_len    .mbuild/deps/vecmath/vecmath.mettle:9   C library libmb_vecmath.so (vecmath)
    vm_scale  .mbuild/deps/vecmath/vecmath.mettle:10  C library libmb_vecmath.so (vecmath)
```

Each extern resolves to a C library, a linked library, the Mettle runtime,
or (for Windows) a default DLL. One that resolves nowhere is `UNRESOLVED`,
gets the explanation above, and makes doctor exit 1. It skips files imported
only for the other OS (`import "x" if windows;`, `*.windows.mettle`).

## Caveats

**C stdio is not flushed at exit.** A Mettle program exits without flushing
the C library's buffers. On Linux, `printf` output from C code is lost when
stdout is a pipe or a file:

```text
$ ./build/linux/debug/cio | cat
from Mettle
```

The C function printed `from C` first. Call `fflush(stdout)` in C code that
prints, or make it unbuffered with `setvbuf`.

**Two runtimes, two allocators.** Mettle has its own runtime, with its own
`malloc` and `free`. A C library is linked against the system's C library
(glibc on Linux, the MinGW runtime on Windows), which has another. Memory one
side allocates must be freed by the same side: give the C library a `free`
function of its own and call that from Mettle.

**Structs by value follow the platform ABI.** Mettle passes and returns
structs by value the way C does: the Microsoft x64 rules on Windows (a struct
of exactly 1, 2, 4 or 8 bytes in one register, anything else by pointer) and
System V on Linux (up to 16 bytes in registers, classified per eight bytes;
larger structs in memory). Define each struct with the same fields, in the
same order, with the same types as the C header. `vm_scale` above takes and
returns a `Vec2` by value on both targets. See
[Structs by value](https://github.com/suidvandiewereld/Mettle/blob/main/docs/c-interop.md#structs-by-value).

**Double-precision libm is not in the runtime.** `sqrt`, `sin`, `cos`, `pow`
and friends do not resolve without `-lm`. Use `std/math` instead of declaring
them.

**Tests do not get native libraries.** `mbuild test` runs `mettle test`,
which executes `@test` functions in the compiler's interpreter. mbuild passes
it no native link arguments, so a test that calls into a C library does not
work. Test that code through a built program.
