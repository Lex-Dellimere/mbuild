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

## Two sections

| Section | For |
|---|---|
| `[c]` | C source files that belong to the package. mbuild compiles them into one shared library per package. |
| `[link]` | Libraries that already exist: system libraries, pkg-config packages, prebuilt `.so` and `.dll` files shipped in the repository. |

Both have `.linux` and `.windows` variants whose values are appended for that
target. The keys are listed in [The manifest](manifest.md#c-clinux-cwindows).

## C sources: [c]

The fixture package `github.com/demo/vecmath` wraps three C functions:

```toml
[package]
name = "vecmath"
module = "github.com/demo/vecmath"

[c]
sources = ["csrc"]
include = ["csrc/include"]
cflags = ["-O2"]

[c.linux]
libs = ["m"]
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

A project that imports `github.com/demo/vecmath/vecmath` builds it for each
target with nothing in its own manifest about C:

```text
$ mbuild -v build --force
   Compiling vecmath (C, 1 file)
  > /bin/cc -c .../vecmath/csrc/vec.c -o .../.mbuild/cache/linux/c/vecmath/csrc/vec.c.o -MMD -MF .../vec.c.o.d -fPIC -I .../vecmath/csrc/include -O2
  > /bin/cc -shared -o .../.mbuild/cache/linux/lib/libmb_vecmath.so .../vec.c.o -Wl,-soname,libmb_vecmath.so -lm
   Compiling app (linux, debug)
  > ~/.mbuild/toolchains/v0.17.0/linux/bin/mettle --build src/main.mettle -o build/linux/debug/app -I .mbuild/deps -L/home/you/app/.mbuild/cache/linux/lib -lmb_vecmath --rpath '$ORIGIN'
Built executable 'build/linux/debug/app'
    Finished in 0.0s
```

What happens, per package that has `[c] sources`:

1. Each source is compiled to an object under
   `.mbuild/cache/<target>/c/<package>/`, with a depfile (`-MMD -MF`) that
   records the headers it included. Linux objects add `-fPIC`. Independent
   files compile in parallel (`-j N`, `MBUILD_JOBS`, default 8).
2. The objects are linked into one shared library under
   `.mbuild/cache/<target>/lib/`: `libmb_<package>.so` on Linux,
   `mb_<package>.dll` on Windows. `[c] libs` are the libraries that this C
   code itself needs (`-lm` above). The package's `[link] paths` are passed
   as `-L`. Windows libraries add `-static-libgcc`, so the DLL does not
   depend on MinGW's libgcc DLL.
3. The program's link names every such library, and the library is copied
   beside the binary.

When the package's output depends on the [profile](#c-flags-per-profile),
objects and libraries go to `c-<profile>/` and `lib-<profile>/` instead.

`<package>` is the package's `name`, lowercased, with anything other than
letters, digits and `_` turned into `_`. A package without an `mbuild.toml`
cannot have C code.

The order of libraries on the link puts dependents before their
dependencies.

### C code that calls C code in a dependency

C code may call the C code of the packages it depends on, directly or through
others. mbuild builds the C libraries dependencies first, and for each
package's C:

- compiles with `-I` for every dependency's `[c] include` directories (after
  the package's own), so `#include "capi.h"` finds a dependency's header;
- links its library against every dependency's C library
  (`-L<cache>/lib -lmb_<dep>`, on Linux with `-Wl,-rpath,$ORIGIN`, so it finds
  them beside the binary) and against the dependencies' `[link] libs` (with
  their `[link] paths`; for Windows, a DLL is linked when it is found in those
  paths, on `PATH` or in `system32`, and otherwise left to the program's
  link).

```text
  > /bin/cc -shared -o .../lib/libmb_cuser.so .../u.c.o -Wl,-soname,libmb_cuser.so -L .../lib -lmb_capi '-Wl,-rpath,$ORIGIN'
```

A change to a dependency's header recompiles the dependent's objects that
include it; a rebuilt dependency library relinks its dependents.

### C flags per profile

`[profile.<name>] cflags` in the project's own manifest are appended to the C
flags of every package (the project's and its dependencies') when building
that profile. No profile adds C flags by default, not even `release`; to
optimise C code in release builds:

```toml
[profile.release]
cflags = ["-O2"]
```

A profile with `cflags` keeps its objects and libraries apart
(`.mbuild/cache/<target>/c-release/`, `lib-release/`), so switching between
`debug` and `--release` does not recompile anything twice. A dependency's own
`[profile.*]` sections are ignored, like the rest of its build settings.

### Fingerprints

An object is recompiled when its source, a header it included, its compile
arguments or the C compiler (by name, size and modification time) change; a
library is relinked when an object, a dependency's library or its link
arguments change. Paths inside the project are recorded relative to it and
paths outside in their Linux form, so Linux `mbuild` and `mbuild.exe` under
wine can take turns on one project without recompiling.

## Existing libraries: [link]

### System libraries and pkg-config

```toml
[link.linux]
pkgconfig = ["zlib"]

[link.windows]
libs = ["zlib1"]
```

Each `pkgconfig` name runs `pkg-config --libs NAME`, and its `-L` and `-l`
words go to the link. For the Linux target the program is `$PKG_CONFIG`, else
`pkg-config`. For the Windows target it is `$PKG_CONFIG_WINDOWS`, else
`x86_64-w64-mingw32-pkg-config` (under wine, the host's); its `-l` names
become DLL imports, and its `-L` directories (and the `bin/` beside each,
where MinGW packages keep DLLs) go on the DLL search path of the compile.
Without either, a `pkgconfig` entry is skipped for Windows with a warning:
name the DLL under `[link.windows] libs` instead. `PKG_CONFIG_PATH` reaches
the program as usual.

```mettle
import "std/io";
import "github.com/demo/vecmath/vecmath";

extern fn deflate_bound(n: int64) -> int64 = "compressBound";

fn main() -> int32 {
  println("bound={deflate_bound(100)} {vm_banner()}");
  return 0;
}
```

```text
$ mbuild run
   Compiling app (linux, debug)
    Finished in 0.0s
     Running build/linux/debug/app
bound=113 vecmath!
```

```text
$ readelf -d build/linux/debug/app | grep -i 'needed\|runpath'
 0x0000000000000001 (NEEDED)             Shared library: [libz.so.1]
 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN]
```

The Mettle linker records only the libraries a symbol actually comes from:
`libmb_vecmath.so` is absent above because this program uses none of the C
functions.

### Prebuilt libraries in the repository

```toml
[link]
libs = ["vend"]
paths = ["vendor/lib"]
```

`paths` are directories relative to the package. A library named in `libs`
and found in one of them (`libvend.so` and its versioned names on Linux,
`vend.dll` on Windows) is copied beside the binary:

```text
$ mbuild -v build -t all --force
  > ~/.mbuild/toolchains/v0.17.0/linux/bin/mettle --build src/main.mettle -o build/linux/debug/vend -I .mbuild/deps -L/home/you/vend/vendor/lib -lvend --rpath '$ORIGIN'
  > WINEDEBUG=-all WINEPATH=Z:\home\you\vend\vendor\lib /bin/wine ~/.mbuild/toolchains/v0.17.0/windows/mettle.exe --build src/main.mettle -o build/windows/debug/vend.exe -I .mbuild/deps --link-arg -lvend
$ ls build/*/debug
build/linux/debug:
libvend.so
vend

build/windows/debug:
vend.dll
vend.exe
```

Ship one directory per target and the program finds its libraries.

## What happens on each OS

### Linux

- Every library becomes `-l<name>`, every library directory `-L<dir>`.
- When anything is linked, mbuild adds `--rpath $ORIGIN`, so the program looks
  for libraries in its own directory first.
- C libraries and libraries found under `[link] paths` are copied beside the
  binary. System libraries are not: the machine that runs the program needs
  them installed.
- mbuild never passes `--link-arg` on Linux, so the compiler keeps its
  internal ELF linker.

### Windows

- Every library becomes `--link-arg -l<name>`, which imports `<name>.dll`.
- The Windows compiler checks each DLL by loading it, so the DLL's directory
  must be on the search path during the build. mbuild puts every library
  directory in front of `PATH` for that one compile when mbuild runs on
  Windows (natively or under wine), or in front of `WINEPATH` when Linux
  mbuild runs the Windows compiler through wine. Your own `PATH` and
  `WINEPATH` follow.
- C DLLs and DLLs found under `[link] paths` are copied beside the `.exe`,
  where Windows looks first. DLLs found only on `PATH` or in `system32` are
  not copied.
- The default set (`kernel32`, `user32`, `gdi32`, `advapi32`, `ws2_32`) needs
  no `[link]` entry.

## C compilers

| Target | mbuild uses the first of |
|---|---|
| Linux | `$CC`; `cc`; `gcc`; `clang`. |
| Windows | `$CC_WINDOWS`; `x86_64-w64-mingw32-gcc`; on a Windows host, `gcc` or `clang` that are Windows programs. |

So on Linux, building C code for the Windows target needs MinGW-w64
(`sudo apt install gcc-mingw-w64-x86-64` on Debian and Ubuntu). Under wine,
mbuild finds the host's compilers as host programs: `x86_64-w64-mingw32-gcc`
for the Windows target, `cc` for the Linux one. A real Windows host cannot
compile C for the Linux target.

A C compiler is only looked for when some package has `[c] sources`.

## When the link fails

The compiler's linker stops at the first unresolved symbol. mbuild reads the
compiler's output, checks every other `extern` in the project and its
dependencies, and searches the system's libraries (ELF `.dynsym`, PE export
tables) for each missing name. Then it says where each one was declared, what
defines it, and what to add:

```text
$ mbuild build
   Compiling app (linux, debug)
Error: Native ELF link failed: Unresolved external symbol 'compressBound'
Error: The internal ELF linker could not produce 'build/linux/debug/app'

error: the linux link is missing 1 symbol that nothing on it defines:

  `compressBound`
    declared at src/main.mettle:4 (extern deflate_bound = "compressBound")
    defined in /usr/lib/x86_64-linux-gnu/libz.so (libz.so.1)
    help: to link it, add to mbuild.toml:
        [link.linux]
        libs = ["z"]

also: these externs resolve nowhere on the link either (the linker reports one at a time):

  `cos`
    declared at src/main.mettle:5 (extern fn cos)
    defined in /usr/lib/x86_64-linux-gnu/libm.so.6
    note: `cos` is double-precision math. The Mettle runtime deliberately carries no float64 libm (only the float32 forms such as `cosf`); import "std/math" instead of declaring it (docs/c-interop.md).
    help: or, to link it anyway, add to mbuild.toml:
        [link.linux]
        libs = ["m"]

error: could not compile `app` (linux, debug)
```

The same program for Windows, where wine's `system32` holds a zlib:

```text
$ mbuild run -t windows
   Compiling app (windows, debug)
Warning: Internal linker PE emission failed: Unresolved external symbol 'compressBound'
Error: Internal linker failed to produce an executable

error: the windows link is missing 1 symbol that nothing on it defines:

  `compressBound`
    declared at src/main.mettle:4 (extern deflate_bound = "compressBound")
    defined in ~/.wine/drive_c/windows/system32/zlib1.dll
    help: to link it, add to mbuild.toml:
        [link.windows]
        libs = ["zlib1"]

error: could not compile `app` (windows, debug)
```

A library named in `[link] libs` that is not installed:

```text
Error: Could not find shared library 'libnosuch.so' for -lnosuch on the library search path
Error: The internal ELF linker could not produce 'build/linux/debug/hello'
error: library `nosuch` (from mbuild.toml ([link] libs of hello)) is not installed: no libnosuch.so on the library search path
  help: install its development package (it provides libnosuch.so), or put the directory holding it under [link] paths
```

Each library is listed once: names that are one file (`libz.so`,
`libz.so.1`, `libz.so.1.3.1`, or `/lib` and `/usr/lib` when one is a link to
the other) are shown by the development name `-l` uses, with the soname the
program records in parentheses.

The suggestions skip what cannot work. The Windows C runtime DLLs (`msvcrt`,
`ucrtbase`, `vcruntime`, ...) are never suggested, because the Mettle linker
refuses them; a symbol only they define gets that explanation instead. When
the symbol is defined by a library already on the link, mbuild says so and
suggests `--force`.

## mbuild doctor

`mbuild doctor` runs the same search on demand, for every `extern` of the
project and its dependencies, per target. It skips files imported only under
the other OS's guard (`import "x" if windows;`) and files named
`*.windows.mettle` or `*.linux.mettle` for the other target. It does not
look inside `build/` directories, dot directories, or subdirectories that
are projects of their own (holding an `mbuild.toml`).

```text
$ mbuild doctor -t all
mbuild 0.1.0
  host      linux
  project   app (.)
  home      /home/you/.mbuild
tools
  git       found  /bin/git
  cc        found  /bin/cc
  wine      found  /bin/wine
compilers
  linux     ~/.mbuild/toolchains/v0.17.0/linux/bin/mettle (v0.17.0; newest installed toolchain v0.17.0)
            stdlib ~/.mbuild/toolchains/v0.17.0/linux/stdlib
  windows   ~/.mbuild/toolchains/v0.17.0/windows/mettle.exe (v0.17.0, via wine; newest installed toolchain v0.17.0)
            stdlib ~/.mbuild/toolchains/v0.17.0/windows/stdlib
native
  linux: 3 externs
    vm_dot    .mbuild/deps/github.com/demo/vecmath/vecmath.mettle:8   C library libmb_vecmath.so (github.com/demo/vecmath)
    vm_len    .mbuild/deps/github.com/demo/vecmath/vecmath.mettle:9   C library libmb_vecmath.so (github.com/demo/vecmath)
    vm_scale  .mbuild/deps/github.com/demo/vecmath/vecmath.mettle:10  C library libmb_vecmath.so (github.com/demo/vecmath)
  windows: 3 externs
    vm_dot    .mbuild/deps/github.com/demo/vecmath/vecmath.mettle:8   C library mb_vecmath.dll (github.com/demo/vecmath)
    vm_len    .mbuild/deps/github.com/demo/vecmath/vecmath.mettle:9   C library mb_vecmath.dll (github.com/demo/vecmath)
    vm_scale  .mbuild/deps/github.com/demo/vecmath/vecmath.mettle:10  C library mb_vecmath.dll (github.com/demo/vecmath)
```

Each extern resolves to one of: a C library, a `[link] library`, the
`Mettle runtime` (read from the compiler's runtime objects), or, for Windows,
a `Windows default DLL`. An extern that resolves nowhere is marked
`UNRESOLVED`, gets the explanation shown above, and makes doctor exit with 1.
Without the compiler's runtime objects, runtime names show as unknown rather
than unresolved.

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
