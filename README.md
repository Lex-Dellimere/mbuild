# mbuild

mbuild is a build tool and package manager for [Mettle](https://github.com/suidvandiewereld/Mettle), and it's written in mettle.

it builds mettle programs for linux and windows, from linux or from windows (or wine). deps come straight from git, like go: import `github.com/someone/repo/file` and mbuild fetches it, picks a version, pins the commit in a lock file and builds. if a package has C code in it, mbuild compiles that too and carries it along the dependency chain. it only rebuilds what changed.

```bash
mbuild init
mbuild run
```

## what it does

- builds linux binaries and windows `.exe` files. on linux the `.exe` is built by running the windows mettle compiler through wine. under wine, linux binaries are built with the host's linux compiler
- deps from github (or any git host), go style. versions come from git tags, everything gets pinned in `mbuild.lock`
- spots imports you didn't declare and adds them for you
- C code in packages gets built into a `.so` / `.dll` and linked in, on both platforms
- when a link fails it tells you which `extern` caused it, which library has the symbol, and what to put in `mbuild.toml`
- incremental: unchanged programs are "Fresh", C files only recompile when they or their headers change, passing tests are cached
- downloads the right mettle compiler if you don't have one
- `mbuild test`, `trace`, `why`, `explain` just run the mettle ones inside your project

## install

mbuild is built with mbuild. grab a released binary from the [releases](https://github.com/Mettle-Foundation/mbuild/releases) and you're done, or build it from source:

```bash
git clone https://github.com/Mettle-Foundation/mbuild.git
cd mbuild
mbuild build -r -t host          # build/linux/release/mbuild
```

if you don't have any mbuild yet, one plain mettle command makes a throwaway one and that builds the real thing:

```bash
mettle --build src/main.mettle -o mbuild0
./mbuild0 build -r -t host
```

same on windows with `mettle.exe` and `mbuild0.exe`. get mettle from the [mettle releases](https://github.com/suidvandiewereld/Mettle/releases).

mbuild keeps compilers and git caches in `~/.mbuild` (`%LOCALAPPDATA%\mbuild` on windows). set `MBUILD_HOME` to put it somewhere else.

## a quick tour

### new project

```bash
mkdir hello && cd hello
mbuild init
mbuild run
```

```text
$ mbuild init
     Created mbuild.toml (package `hello`)
     Created src/main.mettle
     Updated .gitignore

  next: mbuild run
$ mbuild run
   Compiling hello (linux, debug)
    Finished in 0.0s
     Running build/linux/debug/hello
Hello from hello!
```

run it again without changing anything and nothing gets compiled:

```text
$ mbuild run
       Fresh hello (linux, debug)
    Finished in 0.0s
     Running build/linux/debug/hello
Hello from hello!
```

### adding a dependency

just import it:

```mettle
import "std/io";
import "github.com/demo/strutil/strutil";

fn main() -> int32 {
  println(su_shout("hi"));
  return 0;
}
```

```text
$ mbuild build
    Fetching github.com/demo/strutil
      Adding github.com/demo/strutil v1.1.0
   Resolving dependencies
   Compiling hello (linux, debug)
    Finished in 0.0s
```

(`github.com/demo/strutil` is one of the test fixtures in `tests/fixtures`, swap in a real package)

`mbuild.toml` now has the dependency and `mbuild.lock` has the exact commit. you can also do it by hand:

```bash
mbuild get github.com/demo/strutil@v1.0.0
mbuild update
mbuild remove github.com/demo/strutil
mbuild deps --tree
```

### windows from linux

```bash
mbuild build -t windows
mbuild run -t windows      # runs the .exe through wine
mbuild build -t all        # both
```

and the other way round, `mbuild.exe` under wine builds the windows target natively and the linux target with the linux compiler:

```bash
wine mbuild.exe build -t all
```

### a package with C in it

a binding package puts its C next to its mettle code and says so in its `mbuild.toml`:

```toml
[package]
name = "vecmath"

[c]
sources = ["csrc"]
include = ["csrc/include"]

[c.linux]
libs = ["m"]
```

```mettle
export struct Vec2 { x: float32; y: float32; }
export extern fn vm_dot(a: Vec2, b: Vec2) -> float32 = "vm_dot";
```

anyone who depends on it gets `libmb_vecmath.so` (or `mb_vecmath.dll`) built and copied next to their binary. system libs go in `[link]`:

```toml
[link]
libs = ["raylib"]

[link.linux]
pkgconfig = ["zlib"]
```

### when a link fails

say you declared `extern fn cos(x: float64) -> float64 = "cos";` and built. after the compiler's own error you get:

```text
error: the linux link is missing 1 symbol that nothing on it defines:

  `cos`
    declared at src/main.mettle:2 (extern fn cos)
    defined in /usr/lib/x86_64-linux-gnu/libm.so.6
    note: `cos` is double-precision math. The Mettle runtime deliberately carries no float64 libm (only the float32 forms such as `cosf`); import "std/math" instead of declaring it (docs/c-interop.md).
    help: or, to link it anyway, add to mbuild.toml:
        [link.linux]
        libs = ["m"]
```

`mbuild doctor` checks every extern in the project before you even build.

## mbuild.toml

only `[package] name` is required. the rest is there when you need it:

```toml
[package]
name = "app"
version = "0.1.0"

[toolchain]
mettle = "v0.17.0"          # pin a compiler, downloaded if missing

[build]
targets = ["linux", "windows"]

[profile.release]
flags = ["--safe"]          # extra compiler flags for -r builds

[bin.app]
main = "src/main.mettle"    # optional, found automatically

[dependencies]
"github.com/demo/vecmath" = "v0.1.0"
mylib = { path = "../mylib" }
```

full reference in [docs/manifest.md](docs/manifest.md).

## commands

| command | what it does |
|---|---|
| `mbuild init` | new project in this folder |
| `mbuild build` | build the programs (`-r` release, `-t linux\|windows\|all`) |
| `mbuild run` | build and run (`-- args` go to the program) |
| `mbuild test` | run `@test` functions, cached |
| `mbuild check` | type check without linking |
| `mbuild clean` | remove build output |
| `mbuild get` / `remove` / `update` / `tidy` | manage deps |
| `mbuild deps` | show the dependency tree |
| `mbuild fetch` | download everything so builds work offline |
| `mbuild doctor` | check tools, compilers and externs |
| `mbuild toolchain` | list, install or pin mettle compilers |
| `mbuild mettle -- ...` | run the selected compiler |
| `mbuild trace` / `why` / `explain` | the mettle subcommands, inside the project |

flags that work everywhere: `-v` (show every command), `-q`, `--offline`, `--locked` (for CI: fail instead of changing the manifest or lock), `-j N`, `--force`.

## docs

- [docs/manifest.md](docs/manifest.md): everything in `mbuild.toml`, the lock, `mettle.deps`
- [docs/dependencies.md](docs/dependencies.md): versions, the lock, get/update/tidy, mirrors and private repos
- [docs/native.md](docs/native.md): C code and C libraries
- [docs/platforms.md](docs/platforms.md): linux, windows, wine, toolchains, env vars
- [docs/incremental.md](docs/incremental.md): what triggers a rebuild
- [docs/compiler-bugs.md](docs/compiler-bugs.md): mettle compiler bugs found while writing this

## building and testing mbuild itself

mbuild has to compile with the mettle v0.17.0 releases and with current mettle source, so every change gets checked with all of them:

```bash
tools/mcheck.sh src/main.mettle            # head, head --release, v0.17.0 linux, v0.17.0 windows (wine)
sh tests/e2e.sh                            # end to end
sh tests/deps_test.sh --wine
sh tests/native_test.sh
sh tests/toolchain_test.sh
```

`DESIGN.md` explains how it all fits together, including every compiler and wine quirk we hit.
