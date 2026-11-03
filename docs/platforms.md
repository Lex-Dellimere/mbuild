# Platforms

mbuild runs on Linux and on Windows, and builds for two targets: `linux` (ELF
executables) and `windows` (PE `.exe` files), both x86-64.

The Mettle compiler links executables only for the OS it runs on. A Windows
`.exe` is therefore built by the Windows compiler and a Linux binary by the
Linux compiler. mbuild keeps one compiler per target and starts each where it
can run.

## Hosts and targets

| mbuild runs on | `-t linux` | `-t windows` |
|---|---|---|
| Linux | The Linux compiler, natively. | The Windows compiler through `wine`. The program runs through `wine` too. |
| Windows | Not possible. | The Windows compiler, natively. |
| Windows build of mbuild under wine | The Linux compiler, started as a host program. The program runs as a host program. | The Windows compiler, inside wine. |

A real Windows host cannot run the Linux compiler, so `-t linux` there stops
with an error that suggests building on Linux or under WSL. mbuild running
under wine can do it, because wine can start Linux programs. On Linux without
wine, `-t windows` stops with an error that says to install wine or set
`MBUILD_WINE`. When `MBUILD_WINE` is set but wrong, the error names the value
and says what is wrong with it:

```text
$ MBUILD_WINE=/opt/wine/bin/wine mbuild build -t windows
error: building for windows on Linux needs wine to run the Windows Mettle compiler, but MBUILD_WINE=/opt/wine/bin/wine does not exist
  help: point MBUILD_WINE at the wine executable, or unset it to search for wine
```

A name that is not on PATH reads "is not found on PATH", and an existing file
that cannot be run reads "is not a program mbuild can run". The download
tools (`MBUILD_CURL`, `MBUILD_TAR`) report a bad value the same way.

The same holds for C code: the Windows target needs a compiler that makes
Windows DLLs (`x86_64-w64-mingw32-gcc` on Linux), and a real Windows host
cannot compile C for Linux. See [Native code](native.md#c-compilers).

Which targets a command builds:

- `-t linux`, `-t windows`, `-t all` (both) or `-t host` (the OS mbuild runs
  on). Repeat it or separate with commas: `-t linux,windows`.
- Without `-t`, `build`, `check` and `doctor` use `[build] targets` from the
  manifest, else the host.
- `run`, `test` and `mettle` use the host without `-t`. `run` takes one
  target; when `[build] targets` lists several, it runs the host's.

```text
$ mbuild build -t all
   Compiling hello (linux, debug)
   Compiling hello (windows, debug)
    Finished in 2.3s
```

## Which compiler builds a target

For each target, mbuild takes the first of:

1. `MBUILD_METTLE_LINUX` or `MBUILD_METTLE_WINDOWS`: a path, or a program
   name on PATH.
2. `--mettle PATH`, for the host target only.
3. The release pinned by `[toolchain] mettle` in `mbuild.toml`, from
   `$MBUILD_HOME/toolchains/<version>/`. It is downloaded when missing, unless
   `--offline` is given.
4. For the host target only: `$METTLE`, then `mettle` on PATH.
5. The newest release installed in `$MBUILD_HOME/toolchains/` for that
   target.
6. The latest release, downloaded, unless `--offline` is given.

`mbuild toolchain` shows what was chosen and why:

```text
$ mbuild toolchain
Installed toolchains (/home/you/.mbuild/toolchains):
  v0.17.0    linux, windows

Selected compilers:
  linux    /home/you/.mbuild/toolchains/v0.17.0/linux/bin/mettle  (newest installed toolchain v0.17.0)
  windows  /home/you/.mbuild/toolchains/v0.17.0/windows/mettle.exe  (newest installed toolchain v0.17.0, through wine)
```

`mbuild doctor` shows the same per target, with the compiler's version, and
`mbuild mettle -- ARGS` runs the chosen compiler:

```text
$ mbuild mettle -- --version
mettle v0.17.0
host: x86_64
target: x86_64-linux (ELF)
```

### Installed toolchains

Releases live in `$MBUILD_HOME/toolchains/<version>/`, laid out like the
release archives:

```text
toolchains/v0.17.0/linux/bin/mettle
toolchains/v0.17.0/linux/stdlib/
toolchains/v0.17.0/linux/runtime/
toolchains/v0.17.0/windows/mettle.exe
toolchains/v0.17.0/windows/stdlib/
toolchains/v0.17.0/windows/runtime/
```

A download fetches `mettle-<version>-linux-x64.tar.gz` or
`mettle-<version>-windows-x64.zip` from
`https://github.com/<repo>/releases/download/<version>/`, where `<repo>` is
`MBUILD_METTLE_REPO` (default `suidvandiewereld/Mettle`). It unpacks into a
temporary directory and moves the result into place, so a broken download
never looks installed. "Latest" is looked up through the GitHub API, falling
back to the redirect of the releases page.

When the release asset does not exist (HTTP 404, usually a mistyped version
or a fork without that release), the error says so and points at
`MBUILD_METTLE_REPO`:

```text
error: downloading https://github.com/suidvandiewereld/Mettle/releases/download/v0.0.99/mettle-v0.0.99-linux-x64.tar.gz failed: not found (404)
  help: check the version (releases: https://github.com/suidvandiewereld/Mettle/releases); to download from another repository set MBUILD_METTLE_REPO=owner/repo
```

The tools a download needs: `curl`; `tar` for the Linux archive; for the
Windows zip, the `tar.exe` that ships with Windows 10 and later, else `unzip`,
`bsdtar` or `python3`.

### mbuild toolchain

| Command | Does |
|---|---|
| `mbuild toolchain` or `mbuild toolchain list` | Installed releases and the compiler selected per target. Downloads nothing. |
| `mbuild toolchain install VERSION [-t T]` | Install a release (`v0.17.0`, `0.17.0` or `latest`). Without `-t`: the host, plus `windows` on Linux when wine is installed, plus `linux` under wine. |
| `mbuild toolchain use VERSION [-t T]` | Install it and write `[toolchain] mettle = "VERSION"` into `mbuild.toml`. Without `-t`, it installs for `[build] targets`, else as `install` does. |
| `mbuild toolchain remove VERSION [-t T]` | Delete a release, or one target of it. |

The compilers' `--version` answers are cached in
`$MBUILD_HOME/toolchains/versions.cache`, keyed by path, size and
modification time, so mbuild does not start wine to ask again.

## Wine

### Linux mbuild, Windows target

On Linux, `-t windows` runs `wine mettle.exe ...` with `WINEDEBUG=-all`, and
`mbuild run -t windows` runs `wine program.exe` the same way, passing its exit
code through. `MBUILD_WINE` names the wine program when it is not `wine` on
PATH.

```text
$ mbuild run -t windows
   Compiling hello (windows, debug)
    Finished in 2.1s
     Running build/windows/debug/hello.exe
hello!
```

Starting wine costs about two seconds per compile in the transcripts on these
pages; Fresh builds start nothing.

When the program links DLLs, mbuild puts their directories (in `Z:\...` form)
in front of `WINEPATH` for the compile. At run time the DLLs sit beside the
`.exe`.

### Windows mbuild under wine

`mbuild.exe` detects wine and reports it:

```text
$ wine mbuild.exe version
mbuild 0.1.0 (windows, under wine)
```

Under wine, mbuild reaches Linux programs (git, cc, x86_64-w64-mingw32-gcc,
pkg-config, curl, tar and the Linux Mettle compiler) as host programs through
drive `Z:`, converting path arguments to their Linux form:

```text
$ wine mbuild.exe doctor -t all
mbuild 0.1.0
  host      windows (under wine)
  project   app (.)
  home      Z:/home/you/.mbuild
tools
  git       found  /usr/bin/git (host program)
  cc        found  /usr/bin/cc (host program)
compilers
  linux     Z:/home/you/.mbuild/toolchains/v0.17.0/linux/bin/mettle (v0.17.0; newest installed toolchain v0.17.0)
            stdlib Z:/home/you/.mbuild/toolchains/v0.17.0/linux/stdlib
  windows   Z:/home/you/.mbuild/toolchains/v0.17.0/windows/mettle.exe (v0.17.0; newest installed toolchain v0.17.0)
            stdlib Z:/home/you/.mbuild/toolchains/v0.17.0/windows/stdlib
...
```

- Wine's `PATH` holds Windows directories only. Host programs (including the
  tools that download releases) are found by searching `MBUILD_UNIX_PATH`, a
  colon-separated list, default
  `/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin`. Linux
  mbuild uses the same list when `PATH` is unset. The scripts that run host
  programs append the list to the inherited `PATH`.
- A program variable may name a Linux path: `MBUILD_GIT=/usr/bin/git` works.
- `MBUILD_HOME` and `MBUILD_GIT_BASE` may be given in Linux form
  (`/home/you/.mbuild`); mbuild reaches them through `Z:`.
- With `MBUILD_HOME` unset, mbuild under wine uses the host user's
  `~/.mbuild`, found through `WINEHOMEDIR`, which wine sets. Linux mbuild and
  wine mbuild then share toolchains and git mirrors.
- The default target is `windows`, the OS mbuild believes it runs on. Pass
  `-t linux` or `-t all` for the other.

Linux mbuild and wine mbuild see the compilers under different paths, and a
build fingerprint includes the compiler's path, so switching between them
rebuilds once ([Incremental builds](incremental.md)).

## Windows programs and batch files

On Windows (and for Windows programs under wine), a program name without an
extension is looked up with each extension of `PATHEXT` in order (default
`.COM;.EXE;.BAT;.CMD`), in the named directory or along `PATH`. Only `.com`,
`.exe`, `.bat` and `.cmd` count; other `PATHEXT` entries such as `.vbs` need
their own hosts and are skipped. A wrapper script such as `cc.bat` therefore
works wherever mbuild takes a program.

A `.bat` or `.cmd` file runs through `cmd.exe` (`%ComSpec%`):

```text
cmd.exe /e:ON /v:OFF /d /s /c ""C:\tools\cc.bat" "arg one" "100%%cd:~,%""
```

The whole line is wrapped in one extra pair of quotes, which `/s` strips;
`/d` skips AutoRun commands and `/v:OFF` keeps `!` literal. Every argument
is quoted, so `^ & | < > ( )` and spaces reach the script literally. Inside an
argument, `"` is doubled, backslashes before a quote are doubled, and `%`
becomes `%%cd:~,%` so that no `%NAME%` expands. The exit code of the script
(`exit /b N`) is the command's.

Limits:

- The script sees `%1` with its quotes; `%~1` removes them. An embedded `"`
  arrives doubled (`"q""uote"`); passed on with `%*` to a program, it
  becomes one quote again.
- An argument holding a line break (or NUL) cannot be passed through
  `cmd.exe`: the command fails to start (exit code 127).
- A script path containing `"` is refused the same way (Windows file names
  cannot contain one).
- What the script itself does with its arguments (unquoted `%~1`, `call`,
  `for`) is up to the script; `cmd.exe` re-parses them there.

## Environment variables

### Locations

| Variable | Meaning |
|---|---|
| `MBUILD_HOME` | mbuild's home: toolchains, git mirrors, scratch files. Default `~/.mbuild`; on Windows `%LOCALAPPDATA%\mbuild`; under wine the host's `~/.mbuild`. |
| `HOME` | Linux: where the default `~/.mbuild` is. |
| `LOCALAPPDATA`, `USERPROFILE` | Windows: where the default home is (`USERPROFILE` when `LOCALAPPDATA` is unset). |
| `WINEHOMEDIR` | Under wine: the host home directory, for the default `MBUILD_HOME`. Set by wine. |
| `TEMP`, `TMP` | Windows: where mbuild writes the scripts it uses to run host programs. Falls back to `%LOCALAPPDATA%\mbuild\tmp`. |

### Compilers and toolchains

| Variable | Meaning |
|---|---|
| `MBUILD_METTLE_LINUX` | The compiler for the Linux target. Overrides everything else. |
| `MBUILD_METTLE_WINDOWS` | The compiler for the Windows target. Overrides everything else. |
| `METTLE` | The compiler for the host target, when no `[toolchain]` pin applies. |
| `MBUILD_METTLE_REPO` | The GitHub `owner/repo` releases are downloaded from. Default `suidvandiewereld/Mettle`. |
| `MBUILD_METTLE_BASE_URL` | Download releases from `<url>/<version>/<asset>` instead of GitHub. A mirror, or `file://` for offline installs. |
| `MBUILD_METTLE_LATEST` | Answer "latest" with this version instead of asking GitHub. |
| `MBUILD_CURL`, `MBUILD_TAR`, `MBUILD_UNZIP`, `MBUILD_BSDTAR`, `MBUILD_PYTHON` | The programs used to download and unpack releases. |

### Dependencies

| Variable | Meaning |
|---|---|
| `MBUILD_GIT` | The git program. |
| `MBUILD_GIT_BASE` | Fetch module `M` from `<base>/M` instead of `https://M`, unless its requirement has a `url`. A directory or a URL. |

### Native code

| Variable | Meaning |
|---|---|
| `CC` | The C compiler for the Linux target. |
| `CC_WINDOWS` | The C compiler for the Windows target. |
| `PKG_CONFIG` | The pkg-config program. |
| `PKG_CONFIG_PATH` | Read by pkg-config itself. |
| `WINEPATH` | Linux, Windows target: mbuild prepends the library directories for the compile and keeps your value after them. |
| `PATH` | Windows: the same, for DLL directories. Everywhere: where programs are found. |
| `WINEPREFIX` | Linux: where wine's `system32` is (default `~/.wine`), searched for DLLs when explaining a failed link. |
| `SystemRoot`, `windir` | Windows: where `system32` is, for the same search. |

### Running and output

| Variable | Meaning |
|---|---|
| `MBUILD_JOBS` | Parallel C compiles. Default 8. `-j N` overrides it and sets it for commands mbuild starts. |
| `MBUILD_WINE` | The wine program. |
| `MBUILD_UNIX_PATH` | Under wine: colon-separated directories searched for host programs. Default `/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin`. |
| `PATHEXT` | Windows: the extensions tried for a program name without one (`.com`, `.exe`, `.bat`, `.cmd` are used). |
| `ComSpec` | Windows: the `cmd.exe` that runs `.bat` and `.cmd` programs. |
| `MBUILD_COLOR` | `always` or `never`. Any other value means auto. `--color` overrides it. |
| `NO_COLOR` | When set, auto color is off. |

mbuild itself sets `WINEDEBUG=-all` for the programs it starts through wine,
and `GIT_TERMINAL_PROMPT=0` and `LC_ALL=C` for git.
