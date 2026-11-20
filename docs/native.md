# native code

a mettle program calls C through `extern fn` declarations. mbuild compiles
C sources, finds libraries, links them for each target and puts the shared
libraries the program needs beside the binary, for every package in the
dependency graph. so a package that wraps a C library works in any project
that imports it.

how `extern` declarations, `cstring`, `rawptr` and structs cross the boundary
is mettle's business: see
[C interoperability](https://github.com/The-Mettle-Project/Mettle/blob/main/docs/c-interop.md)
and [Shared libraries](https://github.com/The-Mettle-Project/Mettle/blob/main/docs/shared-libraries.md).

## two kinds of native code

| calls | for |
|---|---|
| `mb_c_sources`, `mb_c_include`, `mb_c_flags`, `mb_c_libs` | C source files that belong to the package. mbuild compiles them into one shared library per package. |
| `mb_link_libs`, `mb_link_lib_any`, `mb_link_paths`, `mb_pkgconfig` | libraries that already exist: system libraries, pkg-config packages, prebuilt `.so` and `.dll` files shipped in the package. |

each takes a comma-separated list. after `mb_on("linux")` or
`mb_on("windows")` they add to that target only, until `mb_on("")`.

## C sources

the fixture package `vecmath` wraps three C functions:

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

a project that imports `vecmath/vecmath` gets it built for each target with
nothing about C in its own `mbuild.mettle`:

```text
$ mbuild -v build --force
...
   Compiling vecmath (C, 1 file)
...
   Compiling vm (linux, debug)
...
$ ls build/linux/debug
libmb_vecmath.so
vm
```

each package's C sources compile (in parallel, `-j N`) into one shared
library, `libmb_<package>.so` on linux or `mb_<package>.dll` on windows,
which the program links and which is copied beside the binary. `mb_c_libs`
are the libraries the C code itself needs (`-lm` above). windows DLLs are
linked with `-static-libgcc`, so they don't need MinGW's libgcc DLL.

### C code that calls C code in a dependency

a package's C may call the C of the packages it depends on: it compiles with
their include directories (after its own) and links against their libraries
and `mb_link_libs`.

### C flags per profile

`cflags` in a profile of your project are added to every package's C flags
(yours and your dependencies') in that profile. no profile adds C flags by
default, not even `release`:

```mettle
  mb_profile("release");
  mb_set_list("cflags", "-O2");
```

a profile with `cflags` keeps its own objects, so switching between debug and
release doesn't recompile anything twice. a dependency's own profiles are
ignored, and its `mb_c_flags` may not make the compiler run other programs
(`-fplugin`, `-B`, `-wrapper`, `-specs`, `@file`, `-Xclang`) or write
elsewhere (`-o`, `-MF`, `-save-temps`).

## existing libraries

### system libraries and pkg-config

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

each `mb_pkgconfig` name runs `pkg-config --libs NAME` and links its `-L` and
`-l` words. for the linux target that's `$PKG_CONFIG`, else `pkg-config`; for
the windows target `$PKG_CONFIG_WINDOWS`, else
`x86_64-w64-mingw32-pkg-config` (its `-L` directories and the `bin/` beside
each are searched for DLLs). without either, a `pkgconfig` entry is skipped
for windows with a warning: name the DLL with `mb_link_libs` instead.

a library nothing uses doesn't end up in the binary.

### prebuilt libraries in the package

```mettle
  mb_link_libs("vend");
  mb_link_paths("vendor/lib");
```

paths are relative to the package. a library in `mb_link_libs` that is found
in one of them (`libvend.so` and its versioned names on linux, `vend.dll` on
windows) is copied beside the binary:

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

ship one directory per target and the program finds its libraries.

### fallbacks

`mb_link_lib_any` links one library: the first name in its list that the
linker would find. use it when a system ships a library without the
development link (`libsodium.so`), only the versioned file:

```mettle
  mb_link_lib_any("sodium, :libsodium.so.23");
```

`x` means `libx.so` (`x.dll` for windows), `:file` that exact file. mbuild
looks at build time in the `mb_link_paths` directories of the whole build,
then, for linux, `/usr/local/lib/x86_64-linux-gnu /usr/local/lib64
/usr/local/lib /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib
/lib/x86_64-linux-gnu /lib64 /lib`; for windows, `PATH` (on windows) and
system32. each call is one list, `mb_on` applies, and a dependency's pick
links into its dependents like `mb_link_libs`. when nothing is found:

```text
$ mbuild build
error: mb_link_lib_any("openlibm, :libm.so.9") of mathy: no library found for linux (tried libopenlibm.so, libm.so.9)
  help: install one, or add its directory with mb_link_paths in mbuild.mettle; searched the mb_link_paths directories, then the standard ones (docs/native.md)
```

`-v` shows the pick: `mb_link_lib_any("openlibm, m") of mathy: linking m`.

## shipping

on linux the program gets `--rpath $ORIGIN`, so it looks for libraries in its
own directory first; on windows the `.exe`'s directory is searched first
anyway. C libraries and libraries found in `mb_link_paths` are copied there.
system libraries (and DLLs found only on `PATH` or in `system32`) aren't: the
machine that runs the program needs them installed.

on windows, `kernel32`, `user32`, `gdi32`, `advapi32` and `ws2_32` need no
`mb_link_libs`.

## C compilers

| target | mbuild uses the first of |
|---|---|
| linux | `$CC`; `mb_tool("cc", ...)`; `cc`; `gcc`; `clang` |
| windows | `$CC_WINDOWS`; `mb_tool("cc-windows", ...)`; `x86_64-w64-mingw32-gcc`; on a windows host, `gcc` or `clang` |

on linux, C code for the windows target needs MinGW-w64
(`sudo apt install gcc-mingw-w64-x86-64` on Debian and Ubuntu). a real
windows host can't compile C for linux. a C compiler is only looked for when
some package has C sources.

## when the link fails

the compiler's linker stops at the first unresolved symbol. mbuild then
checks every other `extern` in the project and its dependencies, searches
the system's libraries for each missing name, and says where each one was
declared, which library defines it, and what to link. double-precision libm
names (`cos`, `sqrt`, ...) get a note to use `std/math` instead. the windows
C runtime DLLs (`msvcrt`, `ucrtbase`, ...) are never suggested, because the
mettle linker refuses them.

a library you named that isn't installed:

```text
$ mbuild build
   Compiling lk (linux, debug)
Error: Could not find shared library 'libnosuch.so' for -lnosuch on the library search path
Error: The internal ELF linker could not produce 'build/linux/debug/lk'
error: library `nosuch` (from mbuild.mettle (mb_link_libs of lk)) is not installed: no libnosuch.so on the library search path
  help: install its development package (it provides libnosuch.so), or name the directory holding it with mb_link_paths("DIR") in fn project()
error: could not compile lk (linux, debug)
```

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
...
compilers
  linux     /home/you/Mettle/bin/mettle (v0.17.0; $METTLE)
            stdlib /home/you/Mettle/stdlib
native
  linux: 3 externs
    vm_dot    .mbuild/deps/vecmath/vecmath.mettle:8   C library libmb_vecmath.so (vecmath)
    vm_len    .mbuild/deps/vecmath/vecmath.mettle:9   C library libmb_vecmath.so (vecmath)
    vm_scale  .mbuild/deps/vecmath/vecmath.mettle:10  C library libmb_vecmath.so (vecmath)
```

each extern resolves to a C library, a linked library, the mettle runtime,
or (for windows) a default DLL. one that resolves nowhere is `UNRESOLVED`,
gets the explanation above, and makes doctor exit 1. it skips files imported
only for the other OS (`import "x" if windows;`, `*.windows.mettle`).

## caveats

**C stdio is not flushed at exit.** on linux, `printf` output from C code is
lost when stdout is a pipe or a file:

```text
$ ./build/linux/debug/cio | cat
from Mettle
```

the C function printed `from C` first. call `fflush(stdout)` in C code that
prints, or make it unbuffered with `setvbuf`.

**two allocators.** mettle's runtime has its own `malloc` and `free`; the C
library has the system's. memory must be freed by the side that allocated
it: give the C library a `free` function of its own and call that.

**structs by value follow the platform ABI** (Microsoft x64 on windows,
System V on linux), as in C. define each struct with the same fields, order
and types as the C header. see
[Structs by value](https://github.com/The-Mettle-Project/Mettle/blob/main/docs/c-interop.md#structs-by-value).

**double-precision libm is not in the runtime.** `sqrt`, `sin`, `cos`, `pow`
and friends need `-lm`. use `std/math` instead.

**tests and C.** `mbuild test` runs `@test` functions in the compiler's
interpreter, which can't call C; the ones it skips run again as a built
program, linked like the bins ([project](project.md#tests)).
