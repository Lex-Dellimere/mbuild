# Platforms

mbuild runs on Linux and on Windows, and builds for two targets: `linux`
(ELF executables) and `windows` (PE `.exe` files), both x86-64. The Mettle
compiler only links executables for the OS it runs on, so each target has
its own compiler, and mbuild starts each where it can run.

## Hosts and targets

| mbuild runs on | `-t linux` | `-t windows` |
|---|---|---|
| Linux | the Linux compiler | the Windows compiler through `wine`; `mbuild run` runs the `.exe` through wine too |
| Windows | not possible | the Windows compiler |
| Windows mbuild under wine | the Linux compiler, as a host program | the Windows compiler, inside wine |

```text
$ mbuild run -t windows
   Compiling hw (windows, debug)
    Finished in 2.5s
     Running build/windows/debug/hw.exe
Hello from hw!
```

Starting wine costs a second or two per compile; Fresh builds start nothing.

Which targets a command builds:

- `-t linux`, `-t windows`, `-t all` or `-t host`. Repeat it or separate with
  commas: `-t linux,windows`.
- Without `-t`, `build`, `check` and `doctor` use `mb_targets`, else the
  host.
- `run`, `test`, `live` and `mettle` use the host. `run` takes one target:

  ```text
  $ mbuild run -t linux,windows
  error: `mbuild run` runs one target
    help: pass -t linux or -t windows
  ```

On Linux, `-t windows` needs wine (`wine` on PATH, or `MBUILD_WINE`):

```text
$ MBUILD_WINE=/opt/wine/bin/wine mbuild build -t windows
error: building for windows on Linux needs wine to run the Windows Mettle compiler, but MBUILD_WINE=/opt/wine/bin/wine does not exist
  help: point MBUILD_WINE at the wine executable, or unset it to search for wine
```

C code has the same split: see [native code](native.md#c-compilers).

## Toolchains

mbuild keeps Mettle compilers side by side in `~/.mbuild/toolchains/<id>/`:
a release (`v0.17.0`) or a build of a source checkout
(`dev-<git describe>`). Releases up to v0.17.0 can't build current
projects, so for now install from source:

```text
$ mbuild toolchain install --from ~/Mettle
    Building Mettle v0.17.0-466-g5907c5e5 in ~/Mettle (make -j 8)
   Installed Mettle dev-v0.17.0-466-g5907c5e5 in ~/.mbuild/toolchains/dev-v0.17.0-466-g5907c5e5
$ mbuild toolchain default dev-v0.17.0-466-g5907c5e5
     Default Mettle dev-v0.17.0-466-g5907c5e5
$ mbuild toolchain use dev-v0.17.0-466-g5907c5e5
    Updating mbuild.mettle: mb_toolchain("dev-v0.17.0-466-g5907c5e5")
$ mbuild toolchain
Installed toolchains (~/.mbuild/toolchains):
  * dev-v0.17.0-466-g5907c5e5  mettle v0.17.0   from ~/Mettle, 2026-11-04  [default, pinned]

Selected compilers:
  linux    ~/.mbuild/toolchains/dev-v0.17.0-466-g5907c5e5/bin/mettle  (mb_toolchain("dev-v0.17.0-466-g5907c5e5") in mbuild.mettle)
  windows  none: no Mettle compiler for windows
           set MBUILD_METTLE_WINDOWS, or mb_tool("mettle-windows", PATH) in mbuild.local.mettle, to a windows build of Mettle
```

| Command | Does |
|---|---|
| `mbuild toolchain install VERSION` / `latest` | downloads that release for this OS, checks its sha256, unpacks it |
| `mbuild toolchain install --from DIR` | runs `make` in a Mettle checkout and copies its compiler in |
| `mbuild toolchain use V` | pins the project: `mb_toolchain("V")` in `fn project()` |
| `mbuild toolchain use V --local` | writes `mb_tool("mettle-<os>", PATH)` into `mbuild.local.mettle` instead |
| `mbuild toolchain default V` | this machine's default |
| `mbuild toolchain remove V` | deletes it |
| `mbuild toolchain update` | rebuilds `--from` toolchains whose checkout moved on; names a newer release |

`V` is an id or a version. The host compiler is the first of:

1. `--mettle PATH`, then `MBUILD_METTLE_LINUX` / `MBUILD_METTLE_WINDOWS`,
   then `$METTLE`;
2. `mb_tool("mettle-<os>", PATH)` in `mbuild.local.mettle`;
3. the project's `mb_toolchain` pin. Not installed is an error:

   ```text
   error: this project pins Mettle v0.18.0 (mb_toolchain in mbuild.mettle), which is not installed
     help: mbuild toolchain install v0.18.0
   ```
4. the default toolchain;
5. `mettle` on PATH.

The Windows target has only steps 1 and 2 (its variable and `mb_tool`).
`mbuild toolchain` and `-v` say which step won, `mbuild doctor` adds each
compiler's version, and `mbuild mettle -- ARGS` runs the host's.

## Setup

`mbuild setup` creates `~/.mbuild` (`%LOCALAPPDATA%\mbuild` on Windows),
installs the latest release as the default compiler (`--from DIR` for a
source checkout, `--yes` for the one `$METTLE` or PATH came from,
`--no-compiler` for none), checks the tools and whether mbuild is on PATH.
It never edits shell files:

```text
$ mbuild setup --from ~/Mettle
home  ~/.mbuild (the default, created)
compilers
    Building Mettle v0.17.0-466-g5907c5e5 in ~/Mettle (make -j 8)
   Installed Mettle dev-v0.17.0-466-g5907c5e5 in ~/.mbuild/toolchains/dev-v0.17.0-466-g5907c5e5
     Default Mettle dev-v0.17.0-466-g5907c5e5
tools
  curl      found    /usr/bin/curl
  tar       found    /usr/bin/tar
  gcc       found    /usr/bin/gcc
  make      found    /usr/bin/make
  git       found    /usr/bin/git
  wine      found    /usr/bin/wine
PATH  /home/you/.local/bin is not on PATH; add this line to ~/.bashrc (or your shell's rc file):
  export PATH="/home/you/.local/bin:$PATH"
```

`--home DIR` puts the home elsewhere and remembers it in `mbuild.home`
beside the mbuild binary; `MBUILD_HOME` still wins over it. Offline, setup
says so in one line and leaves the compiler for later. Any other command run
before setup creates the home and says `Created ~/.mbuild` once.

## Wine

### Linux mbuild, Windows target

`-t windows` runs `wine mettle.exe ...`, and `mbuild run -t windows` runs
`wine program.exe`, passing its exit code through. DLL directories go in
front of `WINEPATH` for the compile; at run time the DLLs sit beside the
`.exe`.

### Windows mbuild under wine

`wine mbuild.exe` runs Linux programs (cc, pkg-config, curl, tar, the Linux
Mettle compiler) as host programs, searched in `MBUILD_UNIX_PATH` (default
`/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin`). Program
variables and `MBUILD_HOME` may be given in Linux form. With `MBUILD_HOME`
unset it shares the host user's `~/.mbuild` with Linux mbuild. The default
target is `windows`.

Linux mbuild and wine mbuild see the compilers under different paths, so
switching between them rebuilds once ([incremental builds](incremental.md)).

## Windows programs and batch files

A program name without an extension is tried with `.com`, `.exe`, `.bat` and
`.cmd` (from `PATHEXT`), so a wrapper such as `cc.bat` works wherever mbuild
takes a program. Every argument reaches the script quoted and literal; `%~1`
removes the quotes. An argument with a line break can't be passed to a
script.

## Environment variables

### Locations

| Variable | Meaning |
|---|---|
| `MBUILD_HOME` | toolchains, the download cache and scratch files. Default: the `mbuild.home` file beside mbuild, else `~/.mbuild`; on Windows `%LOCALAPPDATA%\mbuild`; under wine the host's `~/.mbuild` |
| `HOME`, `LOCALAPPDATA`, `USERPROFILE`, `WINEHOMEDIR` | where the default home is |
| `TEMP`, `TMP` | Windows: where mbuild writes the scripts that run host programs |

### Compilers

| Variable | Meaning |
|---|---|
| `MBUILD_METTLE_LINUX` | the compiler for the Linux target |
| `MBUILD_METTLE_WINDOWS` | the compiler for the Windows target |
| `METTLE` | the compiler for the host target |
| `MBUILD_METTLE_API` | the release API `mbuild toolchain install` asks (default `https://api.github.com/repos/The-Mettle-Project/Mettle`) |
| `MBUILD_MAKE`, `MBUILD_GIT` | `make` and `git` for `toolchain install --from` |

### Registries

| Variable | Meaning |
|---|---|
| `MBUILD_REGISTRY` | the `default` registry: a URL or a directory (else the Mettle registry) |
| `MBUILD_REGISTRY_<NAME>` | another URL for registry `NAME` (upper case, `-` as `_`): a mirror |
| `MBUILD_CURL`, `MBUILD_TAR` | the programs that download and unpack (also `MBUILD_UNZIP`, `MBUILD_BSDTAR`, `MBUILD_PYTHON` for release zips) |

### Native code

| Variable | Meaning |
|---|---|
| `CC`, `CC_WINDOWS` | the C compiler for each target |
| `PKG_CONFIG`, `PKG_CONFIG_WINDOWS` | the pkg-config program for each target |
| `PKG_CONFIG_PATH` | read by pkg-config itself |
| `WINEPATH`, `PATH` | mbuild puts DLL directories in front for a compile and keeps yours after them |
| `WINEPREFIX`, `SystemRoot`, `windir` | where `system32` is, searched when explaining a failed link |

### Running and output

| Variable | Meaning |
|---|---|
| `MBUILD_JOBS` | parallel compiles, default 8; `-j N` overrides it |
| `MBUILD_WINE` | the wine program |
| `MBUILD_UNIX_PATH` | under wine: where host programs are searched |
| `PATHEXT`, `ComSpec` | Windows: extensions tried for program names, and the `cmd.exe` for scripts |
| `MBUILD_COLOR` | `always` or `never`; anything else means auto. `--color` overrides it |
| `NO_COLOR` | when set, auto colour is off |

mbuild sets `WINEDEBUG=-all` for what it starts through wine, and the
`MBUILD_*` variables of [project commands and hooks](project.md#commands)
for the programs it runs from `mbuild.mettle`.
