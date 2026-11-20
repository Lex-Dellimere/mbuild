# platforms

mbuild runs on linux and on windows, and builds for `linux` (ELF
executables) and `windows` (PE `.exe` files), both x86-64, and for
[RISC-V](#risc-v). the mettle
compiler only links executables for the OS it runs on, so each target has
its own compiler, and mbuild starts each where it can run.

## hosts and targets

| mbuild runs on | `-t linux` | `-t windows` |
|---|---|---|
| linux | the linux compiler | the windows compiler through `wine`; `mbuild run` runs the `.exe` through wine too |
| windows | not possible | the windows compiler |
| windows mbuild under wine | the linux compiler, as a host program | the windows compiler, inside wine |

```text
$ mbuild run -t windows
   Compiling hw (windows, debug)
    Finished in 2.5s
     Running build/windows/debug/hw.exe
Hello from hw!
```

starting wine costs a second or two per compile; Fresh builds start nothing.

which targets a command builds:

- `-t linux`, `-t windows`, a [RISC-V](#risc-v) target, `-t all` or
  `-t host`. repeat it or separate with commas: `-t linux,windows`. `all` is
  the targets `mb_targets` lists, else linux and windows: a RISC-V target
  is built only when it is declared or named.
- without `-t`, `build`, `check` and `doctor` use `mb_targets`, else the
  host.
- `run`, `test`, `live` and `mettle` use the host. `run` takes one target:

  ```text
  $ mbuild run -t linux,windows
  error: `mbuild run` runs one target
    help: pass -t linux or -t windows
  ```

on linux, `-t windows` needs wine (`wine` on PATH, or `MBUILD_WINE`):

```text
$ MBUILD_WINE=/opt/wine/bin/wine mbuild build -t windows
error: building for windows on Linux needs wine to run the Windows Mettle compiler, but MBUILD_WINE=/opt/wine/bin/wine does not exist
  help: point MBUILD_WINE at the wine executable, or unset it to search for wine
```

C code has the same split: see [native code](native.md#c-compilers).

## toolchains

mbuild keeps mettle compilers side by side in `~/.mbuild/toolchains/<id>/`:
a release (`v0.17.0`) or a build of a source checkout
(`dev-<git describe>`). releases up to v0.17.0 can't build current
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

| command | does |
|---|---|
| `mbuild toolchain install VERSION` / `latest` | downloads that release for this OS, checks its sha256, unpacks it |
| `mbuild toolchain install --from DIR` | runs `make` in a mettle checkout and copies its compiler in |
| `mbuild toolchain use V` | pins the project: `mb_toolchain("V")` in `fn project()` |
| `mbuild toolchain use V --local` | writes `mb_tool("mettle-<os>", PATH)` into `mbuild.local.mettle` instead |
| `mbuild toolchain default V` | this machine's default |
| `mbuild toolchain remove V` | deletes it |
| `mbuild toolchain update` | rebuilds `--from` toolchains whose checkout moved on; names a newer release |

`V` is an id or a version. the host compiler is the first of:

1. `--mettle PATH`, then `MBUILD_METTLE_LINUX` / `MBUILD_METTLE_WINDOWS`,
   then `$METTLE`;
2. `mb_tool("mettle-<os>", PATH)` in `mbuild.local.mettle`;
3. the project's `mb_toolchain` pin. not installed is an error:

   ```text
   error: this project pins mettle v0.18.0 (mb_toolchain in mbuild.mettle), which is not installed
     help: mbuild toolchain install v0.18.0
   ```
4. the default toolchain;
5. `mettle` on PATH.

the windows target has only steps 1 and 2 (its variable and `mb_tool`).
`mbuild toolchain` and `-v` say which step won, `mbuild doctor` adds each
compiler's version, and `mbuild mettle -- ARGS` runs the host's.

## setup

`mbuild setup` creates `~/.mbuild` (`%LOCALAPPDATA%\mbuild` on windows),
installs the latest release as the default compiler (`--from DIR` for a
source checkout, `--yes` for the one `$METTLE` or PATH came from,
`--no-compiler` for none), checks the tools and whether mbuild is on PATH.
it never edits shell files:

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
beside the mbuild binary; `MBUILD_HOME` still wins over it. offline, setup
says so in one line and leaves the compiler for later. any other command run
before setup creates the home and says `Created ~/.mbuild` once.

## wine

### linux mbuild, windows target

`-t windows` runs `wine mettle.exe ...`, and `mbuild run -t windows` runs
`wine program.exe`, passing its exit code through. DLL directories go in
front of `WINEPATH` for the compile; at run time the DLLs sit beside the
`.exe`.

### windows mbuild under wine

`wine mbuild.exe` runs linux programs (cc, pkg-config, curl, tar, the linux
mettle compiler) as host programs, searched in `MBUILD_UNIX_PATH` (default
`/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin`). program
variables and `MBUILD_HOME` may be given in linux form. with `MBUILD_HOME`
unset it shares the host user's `~/.mbuild` with linux mbuild. the default
target is `windows`.

linux mbuild and wine mbuild see the compilers under different paths, so
switching between them rebuilds once ([incremental builds](incremental.md)).

## RISC-V

| `-t` | builds | `mbuild run` / `test` runs it on |
|---|---|---|
| `riscv64-linux`, `riscv32-linux` | a static ELF executable | `qemu-riscv64` / `qemu-riscv32` |
| `riscv64-none`, `riscv32-none` | a board image | board `qemu-virt`: `qemu-system-riscv64` / `-riscv32`; `pico2`: rvsim |

the host's compiler builds them all; output goes to
`build/<target>/<profile>/` as for linux. C code (`[c]`, `[link]`) and
shared bins are refused for RISC-V.

```text
$ mbuild run -t riscv64-linux
   Compiling hello (riscv64-linux, debug)
    Finished in 0.0s
     Running build/riscv64-linux/debug/hello (qemu-riscv64)
Hello from hello!
$ echo $?
3
```

a board target needs a board. set it, and the other per-target settings,
after `mb_on(TARGET)` in a profile, or for the bin:

```text
$ mbuild build -t riscv32-none
error: bin hello: a riscv32-none image needs a board (the compiler's boards: esp32c3, esp32c6, esp32h2, esp32p4, pico2, qemu-virt, sifive-e)
  help: mb_set("board", "qemu-virt") after mb_on("riscv32-none") in a profile, or after mb_for_bin
```

```mettle
  mb_profile("debug");
  mb_on("riscv32-none");
  mb_set("board", "qemu-virt");
  mb_on("");
```

```text
$ mbuild run -t riscv32-none
   Compiling hello (riscv32-none, debug)
    Finished in 0.0s
     Running build/riscv32-none/debug/hello.bin (qemu-system-riscv32)
Hello from hello!
```

the image exits through QEMU's test device, so the exit status is what
`main` returned (3 here).

| setting | values | |
|---|---|---|
| `board` | a board of the compiler (`mettle help riscv`) | board targets only |
| `outputs` | `bin`, `uf2`, `elf`, `hex` (default `bin, elf`) | `NAME.bin` raw, `NAME.uf2` (pico2 only), `NAME.elf` for a debugger (with `-g`: `debug-info = true`), `NAME.hex` Intel HEX |
| `objective` | `balanced`, `size`, `speed` | what `--release` optimizes for |
| `isa` | e.g. `rv32imac_zba_zbb_zbs_zcb_zcmp` | starts with the target's `rv32` / `rv64` |
| `abi` | `ilp32`, `ilp32e`, `ilp32f`, `ilp32d`, `lp64`, `lp64f`, `lp64d` | of the target's width; the compiler has no `lp64e` |
| `pie` | bool (false) | `riscv*-linux` only: a position-independent executable (`--pie`), with a compiler that has it |

`optimize` and `debug-info` work as on linux; `stack-trace` and
`check-effects` are left out (a RISC-V program has no crash report and no
effect runtime). a `riscv*-linux` program is static unless `pie = true`
makes it position-independent. a setting on the wrong target stops the
build and says where it goes:

```text
error: bin hello: board = "qemu-virt" is for a board image (riscv32-none or riscv64-none), and this is "linux"; set it after mb_on("riscv32-none") in a profile, or for that bin only
```

a Pico 2 image runs on rvsim, the Mettle project's RP2350 simulator.
`rvsim-until-ms`, `exit-on-uart`, `uart-script` (bytes for the console's
input) and `pins` set it up; the console is its output:

```mettle
fn project() {
  mb_package("blink", "0.1.0");
  mb_targets("riscv32-none");
  mb_for_bin("blink");
  mb_set("board", "pico2");
  mb_set("outputs", "uf2, bin, elf");
  mb_set("rvsim-until-ms", "1000");
  mb_set("exit-on-uart", "done");
}
```

```text
$ mbuild run
   Compiling blink (riscv32-none, debug)
    Finished in 1.0s
    Building rvsim from /home/you/Mettle/tools/riscv-sim
     Running build/riscv32-none/debug/blink.bin (rvsim)
blink 0
blink 1
blink 2
donerp2350: UART0 printed the --exit-on-uart string at 3.854 ms
```

`build/riscv32-none/debug/blink.uf2` is the file for the board's drive.
other boards have no emulator here unless a package declares a runner for
them ([boards from packages](#boards-from-packages)); `mbuild flash` writes
them ([flashing](#flashing-and-monitoring)).

under an emulator `run` and `test` stop the program after 30 seconds, or
`--timeout SECS`; the status is then 124:

```text
$ mbuild run spin -t riscv64-linux --timeout 1
   Compiling spin (riscv64-linux, debug)
    Finished in 0.0s
     Running build/riscv64-linux/debug/spin (qemu-riscv64)
spinning
error: build/riscv64-linux/debug/spin was stopped after 1.0s (--timeout 1)
```

`@test` functions run in the compiler's interpreter whatever the target;
test programs run on the emulator. a Pico 2 program never exits, so a test
program there passes when its console prints the `exit-on-uart` string
(default `PASS`; call `pico2_init()` first) before `rvsim-until-ms`
(default 10000 for a test) runs out.

### boards from packages

a package can declare boards in `fn project()`; a project that depends on it
picks one with `mb_set("board", NAME)` as before:

```mettle
fn project() {
  mb_package("rp2350", "0.1.0");
  mb_board("pico2", "src/board/pico2.mettle");
  mb_board_set("pico2", "target", "riscv32-none");
  mb_board_set("pico2", "runner", "rvsim --machine rp2350");
  mb_board_set("pico2", "outputs", "bin, uf2");
  mb_board_set("pico2", "flash", "mflash write --board pico2");
}
```

mbuild looks the name up in the project, then in every dependency (direct
or not), and passes the board file's absolute path to `mettle --board`. a
name no package declares goes to the compiler as is, so its own boards keep
working. two packages declaring one name is an error naming both.

| key | meaning |
|---|---|
| `target` | the target `flash`, `monitor` and on-board tests use when nothing else names one |
| `outputs` | the default for the projects that use it; their own `outputs` wins |
| `runner` | what runs its images for `run` and `test`, instead of mbuild's choice by name: `rvsim ...` gets `--load NAME.bin` and the rvsim settings, any other program the image's path (`.bin`, else `.elf`) last (`mflash` is found as `mbuild flash` finds it; [tests](#runners-from-packages)); `none` for no emulator |
| `flash` | the command `mbuild flash` runs, the image's path last |

`mbuild boards` lists them, then the compiler's:

```text
$ mbuild boards
board  package  target        runner                  file
pico2  rp2350   riscv32-none  rvsim --machine rp2350  ../rp2350/src/board/pico2.mettle
the compiler's boards: esp32c3, esp32c6, esp32h2, esp32p4, pico2, qemu-virt, sifive-e
```

### testing on several targets

`mbuild test` runs each test in every cell of its matrix
([project](project.md#tests)); a cell without a target runs on each target
of `-t`, else of `mb_test_targets`, else the host. a board target names its
board after a colon:

```mettle
  mb_test_targets("host, riscv64-linux, riscv32-none:pico2");
```

```text
$ mbuild test
     Testing linux/debug
     Testing riscv64-linux/debug
     Testing riscv32-none:pico2/debug
test src/main.mettle (linux/debug, riscv64-linux/debug, riscv32-none:pico2/debug) ... ok  0.0s  1 check
    riscv32-none:pico2/debug skipped: @test functions run on hosted targets
test pass (linux/debug, riscv64-linux/debug, riscv32-none:pico2/debug) ... ok  0.1s
test fail (linux/debug, riscv64-linux/debug, riscv32-none:pico2/debug) ... FAILED

failures:

---- fail (linux/debug): exit 1
stdout:
  FAIL
kept: .mbuild/test-run/linux-debug/fail/1

---- fail (riscv64-linux/debug): exit 1
stdout:
  FAIL
kept: .mbuild/test-run/riscv64-linux-debug/fail/1

---- fail (riscv32-none:pico2/debug): no PASS on the console
stdout:
  FAIL
stderr:
  rp2350: stopped at --until-ms (300.000 ms of simulated time)
kept: .mbuild/test-run/riscv32-none-pico2-debug/fail/1

test             linux/debug  riscv64-linux/debug  riscv32-none:pico2/debug
src/main.mettle  ok           ok                   skip[1]
pass             ok           ok                   ok
fail             FAIL         FAIL                 FAIL
[1] @test functions run on hosted targets

test result: FAILED. 2 passed, 1 failed, 1 skipped, 1 check (0.8s)
```

`@test` functions run for hosted targets (linux, windows, `riscv*-linux`),
not for a board. test programs run natively, through wine, under QEMU or on
rvsim; when that program is missing, they count as skipped, with the
reason, and don't fail the run. `--matrix=CELLS` replaces the cells for
one run: `mbuild test --matrix=linux/release,riscv64-linux/debug`. code
that differs per target can be a [component](components.md) picked with
`mb_use` after `mb_on`.

### simulated devices

a test program on rvsim can have devices on its buses, and its own
simulator arguments:

```mettle
  mb_test_set("sensor", "devices", "bme280:t=25,p=101325,h=40; ssd1306:addr=0x3c");
  mb_test_set("sensor", "sim-args", "--until-ms 2000");
```

each spec of `devices` (separated by `;`, as specs hold commas) becomes
`--device SPEC` on the rvsim command line; `sim-args` is split into words
and goes last on the emulator's command line (a cell run natively ignores
it). a cell whose runner isn't rvsim is skipped, with the reason:

```text
$ mbuild test
   Compiling test sensor (riscv32-none, debug)
test sensor (riscv32-none/debug) ... ok  0.0s
test result: ok. 1 passed, 0 failed (0.3s)
$ mbuild test -t linux sensor
test sensor (debug) ... skipped (devices need rvsim, and this cell runs natively)
test result: ok. 0 passed, 0 failed, 1 skipped (0.0s)
```

### simulator settings per test

a test program on a board passes when its console prints a text. three test
settings (`"*"` is the default, a test's own value wins, and both win over
the bin's `exit-on-uart`, `rvsim-until-ms` and `uart-script`) set it up:

| key | rvsim flag | default |
|---|---|---|
| `exit-on-uart` | `--exit-on-uart TEXT` | the bin's, else `PASS` on pico2 |
| `until-ms` | `--until-ms N` | the bin's, else 10000 on pico2 |
| `uart-script` | `--uart-script FILE` (rvsim's script of sends and waits, not the bin's `--uart-in`) | the bin's |

```mettle
  mb_test_set("boot", "exit-on-uart", "booted");
  mb_test_set("boot", "until-ms", "200");
```

a run that never prints the text fails naming the text it waited for:

```text
$ mbuild test
test boot (riscv32-none:pico2/debug) ... ok  0.0s
test hang (riscv32-none:pico2/debug) ... FAILED

failures:

---- hang (riscv32-none:pico2/debug): no never printed on the console
stdout:
  booted
stderr:
  rp2350: stopped at --until-ms (50.000 ms of simulated time)
kept: .mbuild/test-run/riscv32-none-pico2-debug/hang/1

test result: FAILED. 1 passed, 1 failed (3.9s)
```

### runners from packages

a board whose `runner` starts with `mflash` gets mflash as `mbuild flash`
does (`MBUILD_MFLASH`, a dependency's bin named `mflash`, PATH), then
`--until TEXT --timeout S` (the test's `exit-on-uart`, default `PASS`, and
its time limit) and the image's path last. its exit status says whether the
text came. whatever the runner, exit status 77 means the emulator isn't
installed: the cell is skipped with that reason and the run doesn't fail.
`expect-status` and `expect-output` ([project](project.md#tests)) check
emulated runs too.

```text
$ mbuild test
   Compiling test boot (riscv32-none, debug)
test boot (riscv32-none:hwsim/debug) ... ok  0.0s
test result: ok. 1 passed, 0 failed (0.1s)
$ mbuild -v test --force
  > ... mflash run --board hwsim --until booted --timeout 10 .mbuild/test-bins/riscv32-none/debug/boot.bin
$ HW=absent mbuild test --force
test boot (riscv32-none:hwsim/debug) ... skipped (emulator not installed: mflash exited 77)
test result: ok. 0 passed, 0 failed, 1 skipped (0.1s)
```

### flashing and monitoring

`mbuild flash [BIN] [--port TTY]` builds the bin's image and runs the
board's `flash` command, then `--port TTY` when given, then the image (its
first output that isn't `elf`). a board without a `flash` command gets
`mflash write --board NAME`. `mflash` is the `flash` package's program:

1. `MBUILD_MFLASH`;
2. a dependency with a bin named `mflash`, built for the host into
   `build/<host>/<profile>/` as `mb_dep_bin` builds;
3. `mflash` on PATH.

```text
$ mbuild flash --port /dev/ttyACM0
   Compiling blink (riscv32-none, debug)
    Finished in 0.1s
    Flashing build/riscv32-none/debug/blink.bin (mflash)
```

`mbuild monitor [--port TTY] [--until TEXT] [--timeout S]` runs `mflash
monitor` with those flags: the board's console, until TEXT or S seconds.

`mbuild test --on-board [--port TTY]` runs the board test programs on the
board, one at a time: each is flashed as above, then `mflash monitor`
waits for its `exit-on-uart` text (default `PASS`) until its timeout (30 s
by default); a failed flash or no text fails it. on-board runs are never
cached, and tests with `devices` are skipped:

```text
$ mbuild test --on-board --port /dev/ttyACM0
   Compiling test hello (riscv32-none, debug)
    Flashing hello (riscv32-none/debug)
test hello (riscv32-none/debug) ... ok  0.0s
test sensor (riscv32-none/debug) ... skipped (devices need rvsim, and this cell runs on the board (--on-board))
test result: ok. 1 passed, 0 failed, 1 skipped (0.2s)
```

without mflash, `mbuild flash` copies a `pico2` image to the board's drive
as a UF2 (adding `uf2` to `outputs` when it's missing). hold BOOTSEL while
plugging the board in: it mounts as a drive labelled RP2350, which mbuild
looks for under `/run/media/$USER`, `/media/$USER` and `/mnt`, or takes
from `MBUILD_FLASH_DIR`. it writes `NAME.uf2`, syncs, and the board
restarts into the program:

```text
$ mbuild flash
   Compiling blink (riscv32-none, debug)
    Finished in 0.1s
    Flashing build/riscv32-none/debug/blink.uf2 to /run/media/you/RP2350
     Flashed blink (6656 bytes); the board restarts into it
$ mbuild flash
error: no RP2350 drive is mounted (looked in /run/media/you, /media/you, /mnt)
  help: hold BOOTSEL while plugging the board in, then run mbuild flash again (or set MBUILD_FLASH_DIR to the drive)
```

other boards need mflash:

```text
$ mbuild flash
error: flashing board esp32c3 needs mflash, and there is none
  help: add the flash package (mb_dep("flash", ...)) or install mflash (on PATH, or MBUILD_MFLASH)
```

the target is the bin's own triple, else `-t`, else the board target of
`mb_targets`, else the declared board's `target`, else `riscv32-none`.

### profile-guided builds

a counting build (`--pgo-gen`) records how often each block runs; a build
with `--pgo-use` optimizes with those counts. by hand:

```text
$ mbuild build -r --pgo-gen
$ mbuild run -r --pgo-gen -- input.txt
     Running build/linux/release/app
    Profiled .mbuild/pgo/app-linux.prof; build with --pgo-use to use it
$ mbuild build -r --pgo-use
```

`mbuild pgo [BIN]` does the three steps (release unless `-p`, the same
profile for both builds so the blocks match); `mbuild pgo collect` stops
after the run. `-t` picks the target as for `run`. the profile is
`.mbuild/pgo/BIN-TARGET.prof`, or `--pgo-use=FILE`.

a linux program, `riscv*-linux` under QEMU included, writes the profile
when `main` returns (mbuild sets `METTLE_PROFILE_OUT`). a board prints its
counts on the console instead: mbuild captures the run's console into
`.mbuild/pgo/BIN-TARGET.prof.console` and turns it into the profile with
`tools/riscv-pgo-capture.py` of the compiler's mettle checkout (python3, or
`MBUILD_PYTHON`). `main` has to return before the emulator stops, so drop
`exit-on-uart` and leave `rvsim-until-ms` room for the training run.
RISC-V counting needs a compiler with RISC-V `--pgo-gen`; with an older one
the run writes no profile and mbuild says so.

where the emulators come from:

| program | found as |
|---|---|
| `qemu-riscv64`, `qemu-riscv32` | in `MBUILD_QEMU_USER_DIR`, else `~/.local/opt/qemu-user/bin`, else PATH |
| `qemu-system-riscv64`, `qemu-system-riscv32` | PATH (Debian: `qemu-system-misc`) |
| `rvsim` | `MBUILD_RVSIM`, PATH, `$MBUILD_HOME/tools/rvsim`; else built there once with gcc from `tools/riscv-sim/rvsim.c` of the mettle checkout `$METTLE` or the compiler comes from |

## windows programs and batch files

a program name without an extension is tried with `.com`, `.exe`, `.bat` and
`.cmd` (from `PATHEXT`), so a wrapper such as `cc.bat` works wherever mbuild
takes a program. every argument reaches the script quoted and literal; `%~1`
removes the quotes. an argument with a line break can't be passed to a
script.

## environment variables

### locations

| variable | meaning |
|---|---|
| `MBUILD_HOME` | toolchains, the download cache and scratch files. default: the `mbuild.home` file beside mbuild, else `~/.mbuild`; on windows `%LOCALAPPDATA%\mbuild`; under wine the host's `~/.mbuild` |
| `HOME`, `LOCALAPPDATA`, `USERPROFILE`, `WINEHOMEDIR` | where the default home is |
| `TEMP`, `TMP` | windows: where mbuild writes the scripts that run host programs |

### compilers

| variable | meaning |
|---|---|
| `MBUILD_METTLE_LINUX` | the compiler for the linux target |
| `MBUILD_METTLE_WINDOWS` | the compiler for the windows target |
| `METTLE` | the compiler for the host target |
| `MBUILD_METTLE_API` | the release API `mbuild toolchain install` asks (default `https://api.github.com/repos/The-Mettle-Project/Mettle`) |
| `MBUILD_MAKE`, `MBUILD_GIT` | `make` and `git` for `toolchain install --from` |
| `MBUILD_QEMU_USER_DIR` | the directory of `qemu-riscv64` and `qemu-riscv32` |
| `MBUILD_RVSIM` | the rvsim that runs `pico2` images |
| `MBUILD_FLASH_DIR` | the mounted RP2350 drive `mbuild flash` copies to |

### registries

| variable | meaning |
|---|---|
| `MBUILD_REGISTRY` | the `default` registry: a URL or a directory (else the mettle registry) |
| `MBUILD_REGISTRY_<NAME>` | another URL for registry `NAME` (upper case, `-` as `_`): a mirror |
| `MBUILD_CURL`, `MBUILD_TAR` | the programs that download and unpack (also `MBUILD_UNZIP`, `MBUILD_BSDTAR`, `MBUILD_PYTHON` for release zips) |

### native code

| variable | meaning |
|---|---|
| `CC`, `CC_WINDOWS` | the C compiler for each target |
| `PKG_CONFIG`, `PKG_CONFIG_WINDOWS` | the pkg-config program for each target |
| `PKG_CONFIG_PATH` | read by pkg-config itself |
| `WINEPATH`, `PATH` | mbuild puts DLL directories in front for a compile and keeps yours after them |
| `WINEPREFIX`, `SystemRoot`, `windir` | where `system32` is, searched when explaining a failed link |

### running and output

| variable | meaning |
|---|---|
| `MBUILD_JOBS` | parallel compiles, default 8; `-j N` overrides it |
| `MBUILD_WINE` | the wine program |
| `MBUILD_UNIX_PATH` | under wine: where host programs are searched |
| `PATHEXT`, `ComSpec` | windows: extensions tried for program names, and the `cmd.exe` for scripts |
| `MBUILD_COLOR` | `always` or `never`; anything else means auto. `--color` overrides it |
| `NO_COLOR` | when set, auto colour is off |

mbuild sets `WINEDEBUG=-all` for what it starts through wine, and the
`MBUILD_*` variables of [project commands and hooks](project.md#commands)
for the programs it runs from `mbuild.mettle`.
