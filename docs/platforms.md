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

## Which compiler builds a target

mbuild needs a Mettle compiler built from the Mettle source; the v0.17.0
release and older can't build current projects. For each target it uses the
first of:

1. `MBUILD_METTLE_LINUX` / `MBUILD_METTLE_WINDOWS` (a path, or a name on PATH);
2. `mb_tool("mettle-linux", PATH)` / `mb_tool("mettle-windows", PATH)` in
   `mbuild.local.mettle`;
3. `--mettle PATH`, for the host target;
4. for the host target, `$METTLE`, then `mettle` on PATH.

Nothing is downloaded on its own. `mbuild toolchain` shows what was picked
and why:

```text
$ mbuild toolchain
Installed toolchains (/home/you/.mbuild/toolchains):
  (none)

Selected compilers:
  linux    /home/you/Mettle/bin/mettle  ($METTLE)
  windows  none: no Mettle compiler for windows
           set MBUILD_METTLE_WINDOWS, or mb_tool("mettle-windows", PATH) in mbuild.local.mettle, to a windows build of ../Mettle
```

`mbuild doctor` shows the same with each compiler's version (every
development build reports v0.17.0), and `mbuild mettle -- ARGS` runs the
host's.

`mbuild toolchain install VERSION` downloads a release into
`$MBUILD_HOME/toolchains/`, and `mbuild toolchain use VERSION` writes it into
`mbuild.local.mettle` as `mb_tool("mettle-<os>", PATH)`, for programs that
still build with an old release.

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
| `MBUILD_HOME` | the download cache and scratch files. Default `~/.mbuild`; on Windows `%LOCALAPPDATA%\mbuild`; under wine the host's `~/.mbuild` |
| `HOME`, `LOCALAPPDATA`, `USERPROFILE`, `WINEHOMEDIR` | where the default home is |
| `TEMP`, `TMP` | Windows: where mbuild writes the scripts that run host programs |

### Compilers

| Variable | Meaning |
|---|---|
| `MBUILD_METTLE_LINUX` | the compiler for the Linux target |
| `MBUILD_METTLE_WINDOWS` | the compiler for the Windows target |
| `METTLE` | the compiler for the host target |
| `MBUILD_METTLE_REPO`, `MBUILD_METTLE_BASE_URL`, `MBUILD_METTLE_LATEST` | where `mbuild toolchain install` downloads releases from |

### Registries

| Variable | Meaning |
|---|---|
| `MBUILD_REGISTRY` | the `default` registry: a URL or a directory |
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
