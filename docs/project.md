# The project file: mbuild.mettle

`mbuild.mettle` sits at the project root (mbuild walks up from the working
directory to find it) and is Mettle code. `fn project()` describes the
package, `fn deps()` its dependencies, every `fn cmd_NAME` is a command, `fn hook_pre_build` and
`fn hook_post_build` run around builds.

```mettle
import "mbuild/api";

fn project() {
  mb_package("viewer", "0.3.0");
  mb_meta("description", "image viewer");

  mb_profile("release");
  mb_set("crash-report", "false");
  mb_on("windows");
  mb_set("subsystem", "windows");
  mb_on("");
}

fn deps() {
  mb_dep("strutil", "v1.1.0");
}

// install: build a release and copy it into a bin directory (default ~/.local/bin)
//
// mbuild install --to DIR puts it somewhere else.
fn cmd_install(a: MbArgs*) -> int32 {
  var dir: string = mb_opt(a, "--to", mb_home() + "/.local/bin");
  if (mb_mbuild("build -r -t host") != 0) { return 1; }
  mb_mkdirs(dir);
  var dst: string = dir + "/viewer" + mb_exe_ext();
  if (!mb_copy(mb_out("viewer", mb_os(), "release"), dst)) { mb_fail("cannot copy to " + dst); }
  mb_say("installed " + dst);
  return 0;
}

// regenerate src/version.mettle from the package version
fn hook_pre_build() -> int32 {
  mb_write_if_changed("src/version.mettle", "export const VIEWER_VERSION: string = \"" + mb_version() + "\";\n");
  return 0;
}
```

A file that doesn't compile shows the compiler's error, then
`error: mbuild.mettle does not compile`.

`mbuild.toml` is not read any more; a project or path dependency that only
has one gets an error. `mbuild init` writes an `mbuild.mettle`.

## Rules

- `fn project()` is required, `fn deps()` optional. No `fn main`.
- Import the API plainly: `import "mbuild/api";`, never `as`.
- If the file exports anything, `project`, `deps`, every `cmd_*` and every `hook_*`
  must be `export fn` too.
- Don't define names starting with `mb_`, `Mb` or `mbi_`.
- It may import other files of the project.
- Every value is a string. A list is comma-separated: `"linux, windows"`.
  Booleans in `mb_set` are `"true"` / `"false"`.

## fn project()

It must give the same result on every machine, so it can't read the
environment, files or the clock:

```text
error: mbuild.mettle: mb_env cannot be used in fn project() (the project description must be the same on every machine; use mbuild.local.mettle, a command, or a hook)
```

Per-OS settings go through `mb_on(os)`.

### Package

| Call | Meaning |
|---|---|
| `mb_package(name, version)` | Required. `name` is `[a-z][a-z0-9_]*`, at most 64 characters; `std` and `mbuild` are reserved. |
| `mb_meta(key, value)` | `description`, `license`, `repository` or `authors`. Shown to people who depend on the package. |
| `mb_targets(csv)` | What `build`, `check` and `doctor` build without `-t`: `"linux"`, `"windows"`, a RISC-V target. Default: the host. |
| `mb_test_targets(csv)` | The targets `mbuild test` runs on as a matrix: `"host, riscv64-linux, riscv32-none:pico2"` ([platforms](platforms.md#testing-on-several-targets)). |
| `mb_flags(csv)` | Raw compiler flags for every compile. Prefer typed settings (below). |
| `mb_prelude(on)` | Pass `--prelude`, so `std/prelude` is imported everywhere. |
| `mb_agents(on)` | Keep the dependencies block in `AGENT.rules` ([packages](packages.md#agentrules)). Default `true`. |
| `mb_publish_include(csv)` | The files `mbuild publish` packs ([dependencies](dependencies.md#publishing)). |
| `mb_import_root(dir)` | Imports of `name/...` start in `dir` instead of the package root ([dependencies](dependencies.md#import-roots)). |
| `mb_registry(name, url)` | A registry, searched in call order before `default`. |
| `mb_toolchain(v)` | The Mettle toolchain this project builds with, an id or version (`mbuild toolchain use`, [platforms](platforms.md#toolchains)). |
| `mb_raw(section, key, toml)` | Escape hatch: a raw key in the generated manifest. |

### fn deps()

Dependencies go in `fn deps()`, which runs right after `fn project()` and
follows the same rules. `mbuild init` writes an empty one.

| Call | Meaning |
|---|---|
| `mb_dep(name, version)` | A package from the registries, `"v1.2.0"` or higher. |
| `mb_dep_from(registry, name, version)` | The same, from one named registry. |
| `mb_dep_path(name, path)` | A package in a local directory. |
| `mb_dep_bin(dep, bin)` | Also build bin `bin` of dependency `dep` (below). |
| `mb_replace_version(name, version)` | One version of `name` for the whole build. |
| `mb_replace_path(name, path)` | Use a local directory instead of `name` everywhere in the build. |

In `fn project()` these still work, with a warning:

```text
warning: mbuild.mettle:5: mb_dep belongs in fn deps()
  help: mbuild tidy moves it
```

`get`, `remove`, `update`, `tidy` and auto-add edit the `mb_dep*` lines and
leave the rest of the file alone. New lines go into `fn deps()`, which they
add after `fn project()` when it's missing. They can only edit a call on
its own line with string literal arguments; anything else gets an error
that shows the line to write. See [dependencies](dependencies.md).

### Bins

| Call | Meaning |
|---|---|
| `mb_bin(name, main)` | A program built from `main` (relative to the root). |
| `mb_bin_kind(name, kind, triple)` | `exe` (default), `shared`, `object` or `flat` ([components](components.md#bin-kinds)). |
| `mb_for_bin(name)` | Following `mb_set` calls apply to this bin only. |

Without any `mb_bin` or `mb_for_bin`, mbuild finds the programs:

1. `main.mettle`, else `src/main.mettle`, as a bin named after the package;
2. plus every `cmd/<name>/main.mettle`, as a bin named `<name>`;
3. if neither found anything, every top-level `*.mettle` file with `fn main`,
   named after the file.

A bin builds to `build/<target>/<profile>/<bin>`, with `.exe` for Windows.
With several bins, `mbuild run` runs the one named after the package, or
the one you name: `mbuild run tool -- --input data.txt`.

`mb_dep_bin("meosql", "server")` builds a dependency's bin along with
yours, for the same target and profile, with the dependency's own settings
and C code, into the same directory. `mbuild run` starts it when it is
declared a [service](#services).

```text
$ mbuild build
   Compiling meosql (C, 1 file)
   Compiling sass (linux, debug)
   Compiling meosql (C, 1 file)
   Compiling meosql/server (linux, debug)
    Finished in 0.0s
$ ls build/linux/debug
libmb_meosql.so  sass  server
```

A profile the dependency doesn't have falls back to the nearest one it does
(`release` for a profile that inherits `release`). A wrong name lists its
bins:

```text
error: mb_dep_bin("meosql", "sever"): meosql has no bin `sever`
  help: did you mean `server`? meosql's bins are: server
```

A package without bins is a library: `mbuild build` and `mbuild check`
type-check its `.mettle` files at the top and in `src/`, `mbuild test`
works, `mbuild run` says there's nothing to run.

### Tests

`mbuild test` runs three kinds of test, each passing on exit 0:

- an `@test` file: any project file with an `@test` function, run in the
  compiler's interpreter; the tests it skips (they call C) run again as a
  program (below);
- a test program: every `tests/<name>_test.mettle` with `fn main`, or the
  `mb_test_bin` ones, plus each main file an `mb_test_glob` matches. They
  build like the bins (settings, C code, link libraries) into
  `.mbuild/test-bins/`; `mbuild build` never builds them;
- a command test (`mb_test_cmd`): a script or checker. A first word naming
  a test program or a bin is built for the cell and run from there.

| Call | Meaning |
|---|---|
| `mb_test_bin(name, main)` | A test program (`""` = `tests/<name>_test.mettle`); with one, the `tests/` scan is off. |
| `mb_test_glob(glob)` | Every main file matching it is a test program named by its stem: `"examples/*.mettle"`. |
| `mb_test_cmd(name, cmdline)` | A command test, split into words like `mb_service`. |
| `mb_test_exclude(csv)` | Left out of the default set (`@test` files by path); naming one still runs it. |
| `mb_test_set(name, key, value)` | A setting below; name `"*"` sets the default, a test's own value wins. |
| `mb_test_env(name, "K=V")` | A variable in its runs (`"*"` = every test). |

| Key | Default | Meaning |
|---|---|---|
| `matrix` | `debug` | the cells: `PROFILE` or `TARGET/PROFILE`, comma-separated; a cell without a target runs on each of `-t`, else `mb_test_targets`, else the host |
| `timeout` | `600` | seconds per run (30 under an emulator), `0` = none |
| `repeat` | `1` | runs per cell; it passes when all of them do |
| `serial` | `false` | runs alone, after the rest |
| `cwd` | `root` | `root`, or `tmp` (the run's own directory) |
| `warnings` | `allow` | `error`, or `error:M01,W0001`: a build warning (by code prefix) fails it |
| `checks` | | stdout lines starting with this count as checks (`mbuild-checks: N` sets the count) |
| `services` | | `mb_service` names started around each run (fixtures) |
| `args` | | words passed to a test program |
| `run` | `true` | `false`: build only |
| `native` | `skipped` | `@test` files: also run natively what the interpreter `skipped`, `always`, or `never` |
| `golden`, `golden-dir`, `golden-cross`, `png-tolerance` | | see golden files below |
| `ports` | `20000-29999` | `"*"` only: the pool of free ports |

Each (test, cell) runs `repeat` times, at most `-j` at once, every run in
`.mbuild/test-run/<cell>/<name>/<run>/`: `tmp/` (its `TMPDIR`, also
`MBUILD_TEST_TMP`), `out/` (`MBUILD_TEST_OUT`), `stdout`, `stderr`. A run
also gets `MBUILD_ROOT`, `MBUILD_TEST_NAME`, `MBUILD_TEST_CELL` and
`MBUILD_TEST_RUN`, stdin from `/dev/null`, and a process group of its own:
a timeout stops it and whatever it forked. Passing runs are removed
(`--keep` keeps them); failing ones are kept. A passing (test, cell) is
cached until its build, settings or golden files change; `--force`, `--bless`
and `--repeat` above 1 run everything. Outputs of tests that are gone are
removed. The line per test, then each failure once:

```mettle
fn project() {
  mb_package("demo", "0.1.0");
  mb_test_set("*", "matrix", "debug, release");
  mb_test_set("parse", "checks", "PASS");
  mb_test_set("stress", "repeat", "20");
  mb_test_cmd("plot", "sh tests/plot.sh");
}
```

```text
$ mbuild test
     Testing linux/debug
   Compiling test parse (linux, debug)
   Compiling test stress (linux, debug)
     Testing linux/release
   Compiling test parse (linux, release)
   Compiling test stress (linux, release)
test src/calc.mettle (debug, release) ... ok  0.0s  1 check
test parse (debug, release) ... ok  0.0s  3 checks
test stress (debug, release) ... FAILED 2/40
test plot (debug, release) ... ok  0.0s

failures:

---- stress (linux/debug, run 7): exit 1
stdout:
  lost an update on run 7
kept: .mbuild/test-run/linux-debug/stress/7

---- stress (linux/release, run 7): exit 1
stdout:
  lost an update on run 7
kept: .mbuild/test-run/linux-release/stress/7

test result: FAILED. 3 passed, 1 failed, 4 checks (0.3s)
```

`mbuild test NAME...` runs those (a test program, command test or `@test`
file); `--filter S` the ones whose names contain `S`; `--matrix=CELLS`,
`-r` and `-p P` replace the cells, `--repeat N` and `--timeout S` override
for one run, `--deny-warnings` fails every warning, `-q` shows failures
only (`mbuild help test`).

**`@test` natively.** The interpreter can't call C. With `native=skipped`
the tests it skipped run again: mbuild writes a copy of the file to
`.mbuild/test-native/` (same lines, `fn main` renamed, a generated `main`
calling those tests), builds it as a test program in each cell with `-I`
the original's directory, and its result counts. `native=always` runs every
`@test` of the file that way, in every cell.

**Fixtures** are `mb_service`s named in `services`, started for each run as
`mbuild run` starts them, with cwd the run's `tmp/`, and stopped after it
(on timeout too). `mb_service_port(name, 0)` gives each run a free port, so
parallel runs don't collide:

```mettle
  mb_service("db", "meodb --data $MBUILD_TEST_TMP/db --port $MBUILD_PORT_DB");
  mb_service_port("db", 0);
  mb_test_set("live_meodb", "services", "db");
```

**Golden files.** When `tests/golden/<name>/` (`golden-dir`) exists, what a
run writes to `out/` must match it file for file: byte for byte, `.png`
files pixel for pixel. `png-tolerance` `C` or `C,F,H` (default `0`): a pixel
fails when a channel is off by more than `C`, the image when more than a
fraction `F` of pixels fail or any channel is off by more than `H`; a
failing image leaves `NAME.diff.png` (red where it failed) beside it.
`golden = files,stdout` compares stdout too (golden file `stdout`); `off`
skips it. With `golden-cross` (default) every cell's outputs must also
match the first cell's (debug == release, linux == wine). `--bless` writes
the first cell's outputs as the goldens and removes the ones no longer
written; `--only S` limits it to paths containing `S`:

```text
$ mbuild test plot
     Testing linux/debug
     Testing linux/release
test plot (debug, release) ... FAILED

failures:

---- plot (linux/debug): golden out/line.csv differs at line 4
  expected: 2,9
  written:  2,8
kept: .mbuild/test-run/linux-debug/plot/1

---- plot (linux/release): golden out/line.csv differs at line 4
  expected: 2,9
  written:  2,8
kept: .mbuild/test-run/linux-release/plot/1

test result: FAILED. 0 passed, 1 failed (0.0s)
$ mbuild test plot --bless
     Testing linux/debug
     Testing linux/release
test plot (debug, release) ... ok  0.0s
    Blessing tests/golden/plot/line.csv
test result: ok. 1 passed, 0 failed (0.0s)
```

### Documentation

`mbuild doc` writes the API reference (`docs/API.md`) from the comment
block directly above each export: `///` lines when the block has any, else
`//` lines; `//!` lines are the module doc. The first paragraph is the
summary; `@param NAME`, `@return`, `@error`, `@mem`, `@thread`, `@cost`
or `in:`, `returns:`, `owns:`, `thread:`, `example:` lines are fields,
shown as labelled sections. `@internal` (or `//! @internal`) leaves an
export (or a module) out. Struct fields, enum variants and generic
parameters are listed.

| Call | |
|---|---|
| `mb_doc_out(path)` | Where it goes (default `docs/API.md`); set, `mbuild publish` runs `mbuild doc --check` first. |
| `mb_doc_require(csv)` | Fields every function must have: `param`, `returns` (when it returns a value), `in`, `error`, `owns`, `thread`, `cost`, `example`; `in` covers `param`. |
| `mb_doc_exports(csv)` | Only names with one of these prefixes (`"rz_"`); `"!crx_"` drops them. |
| `mb_doc_facade(file)` | Only that file and the modules it imports, in import order. |
| `mb_doc_snippets(csv)` | Markdown files (globs) whose ```` ```mettle ```` blocks `--check` compiles too. |

`mbuild doc --check` writes nothing and exits 1 with `file:line` for an
export without a doc comment or summary, an `@param` that is not a
parameter or is out of order, a required field missing, and an out-of-date
output file. It also compiles each ```` ```mettle ```` block of the doc
comments as a program importing the module (statements become the body of
`main`); a block fenced ```` ```mettle ignore ```` is not compiled.

```text
$ mbuild doc --check
src/ring.mettle:19: ring_push: @param x is not a parameter (r, v)
src/ring.mettle:19: ring_push: parameter v is not documented (@param)
docs/API.md:39: out of date; run `mbuild doc`
    Checking 1 doc snippet
error: docs/API.md: 3 problems
```

With `@param x` renamed to `@param v`:

```text
$ mbuild doc
    Updating docs/API.md
$ mbuild doc --check
    Checking 1 doc snippet
     Checked docs/API.md (2 exports, 1 snippets)
```

### Services

Processes `mbuild run` starts before your program and stops after it, like
a Procfile:

| Call | Meaning |
|---|---|
| `mb_service(name, cmdline)` | A process to run alongside the app. The line is split into words like a shell does (quotes, backslashes), with no other shell features; a first word naming a bin of this project or of `mb_dep_bin` runs it from `build/<target>/<profile>/`. |
| `mb_service_port(name, port)` | Wait until `127.0.0.1:port` accepts a connection before going on; `0` takes a free port from the pool each time it starts. |
| `mb_service_wait(name, ms)` | How long to wait for it (default 10000). |
| `mb_service_env(name, "K=V")` | A variable for that process. |

They start in declaration order, each waited for on its port; then the
program runs; when it exits (Ctrl-C too) they stop in reverse order
(terminated, killed after 2 s), and the exit code is the program's.
`mbuild run --no-services` skips them, `mbuild services` lists them.
Every process (services and app) gets `MBUILD_PORT_<NAME>` (name
upper-cased, other bytes `_`) for each service with a port, and a word may
use `$MBUILD_PORT_<NAME>` and `$MBUILD_ROOT` (in a test, also
`$MBUILD_TEST_TMP` and `$MBUILD_TEST_OUT`); nothing else is expanded. Free
ports come from `mb_test_set("*", "ports", "20000-29999")`, each locked under
`$MBUILD_HOME/tmp/ports/` while in use, so parallel tests and parallel
mbuilds get distinct ones.
Their output goes to `.mbuild/logs/NAME.log`. The fixture server of the
tests (`tests/fixtures/svc_srv.mettle`) as a bin `srv`:

```mettle
fn project() {
  mb_package("app", "0.1.0");
  mb_bin("app", "src/main.mettle");
  mb_bin("srv", "tools/srv.mettle");
  mb_service("db", "srv 6543 db.pid 300");
  mb_service_port("db", 6543);
}
```

```text
$ mbuild run -- 6543 0
   Compiling app (linux, debug)
   Compiling srv (linux, debug)
    Finished in 0.0s
    Starting db (build/linux/debug/srv 6543 db.pid 300)
       Ready db on :6543 (0.3s)
     Running build/linux/debug/app
app got: hi
    Stopping db
$ mbuild services
db  srv 6543 db.pid 300  :6543
```

A service that exits early, or never opens its port, stops the rest and
shows the end of its log:

```text
    Starting db (build/linux/debug/srv 6543 db.pid 0 quiet)
error: service db: port 6543 not open after 1.0s
  last lines of .mbuild/logs/db.log:
    srv 6543: starting
    srv 6543: not listening
    Stopping db
```

### Native code, components, rules

`mb_c_sources`, `mb_c_include`, `mb_c_flags`, `mb_c_libs`, `mb_link_libs`,
`mb_link_lib_any`, `mb_link_paths`, `mb_pkgconfig` are in
[native code](native.md).
`mb_component`, `mb_component_on`, `mb_use` and `mb_rule` are in
[components](components.md).

## Profiles and settings

Build settings are typed keys in a profile:

```mettle
  mb_profile("release");
  mb_set("safe", "true");

  mb_profile("fast");
  mb_inherits("release");
  mb_set("safe", "false");
  mb_set("native-heap", "true");
```

```text
$ mbuild profiles
debug    stack-trace                                                                      -> -s
release  optimize=full, safe (mbuild.mettle:7)                                            -> --release --safe
fast     inherits release; safe=false (mbuild.mettle:11), native-heap (mbuild.mettle:12)  -> --release --native-heap
```

`debug` (the default) and `release` (`-r`) always exist; your calls are
merged over them key by key. Any other profile inherits `debug` unless it
says otherwise, and is picked with `-p NAME`:

```text
$ mbuild -p fats build
error: unknown profile `fats`
  help: did you mean `fast`? the profiles are: debug, release, fast (add mb_profile("fats") to mbuild.mettle)
```

`mb_set` and `mb_set_list` apply to the last `mb_profile` or `mb_for_bin`.
After `mb_on("linux")` or `mb_on("windows")` they (and the C and link calls)
apply to that OS only, until `mb_on("")`. `mb_on` also takes a RISC-V target
(`riscv64-linux`, `riscv32-linux`, `riscv64-none`, `riscv32-none`) for
profile settings; a profile's `linux` settings reach the `riscv*-linux`
targets first ([platforms](platforms.md#risc-v)).

| Key | Values (default) | Passes |
|---|---|---|
| `optimize` | `off`, `checked`, `full` (`full` in release) | nothing, `-O`, `--release` |
| `safe` | bool (false) | `--safe` |
| `stack-trace` | bool (true in debug) | `-s` |
| `debug-info` | bool (false) | `-g` |
| `crash-report` | bool (true) | `--no-crash-report` when false |
| `native-heap` | bool (false) | `--native-heap` |
| `profile-runtime` | bool (false) | `--profile-runtime` |
| `check-overflow`, `check-proofs`, `check-effects`, `check-deadlines`, `check-tasks` | bool (false) | the flag of that name |
| `assume-no-signed-overflow` | bool (false) | `--assume-no-signed-overflow` |
| `verify` | bool (false) | `--verify` |
| `ml-opt` | `off`, `on`, `speculative` | `--ml-opt`, `--ml-opt-speculative` |
| `pgo` | `off`, `auto`, `instrument`, `use` | `--pgo`, `--pgo-gen`, `--pgo-use=FILE` |
| `pgo-file` | path | the profile `pgo = "use"` reads |
| `subsystem` | `console`, `windows` | `--subsystem windows` (Windows only) |
| `image-base` | hex string | `--image-base` |
| `board` | a board name, e.g. `qemu-virt` | `--board NAME`; a `riscv32-none` / `riscv64-none` image needs one |
| `objective` | `balanced`, `size`, `speed` | `--objective NAME`; RISC-V only |
| `isa` | an ISA string, e.g. `rv32imac_zba_zbb` | `--isa`; RISC-V only, of the target's width |
| `abi` | `ilp32`, `ilp32e`, `ilp32f`, `ilp32d`, `lp64`, `lp64f`, `lp64d` | `--abi`; RISC-V only, of the target's width |
| `outputs` | `bin`, `uf2`, `elf`, `hex` (`bin, elf`) | the files a board image writes; `uf2` with `pico2` only |
| `rvsim-until-ms`, `exit-on-uart`, `uart-script`, `pins` | strings | rvsim's `--until-ms`, `--exit-on-uart`, `--uart-in`, `--pins` for `mbuild run` / `test` of a `pico2` image |
| `components` | list of `name=impl` | picks component impls ([components](components.md)) |
| `flags` | list | raw compiler flags, after the typed ones |
| `cflags` | list | C flags for every package's C code in this profile |

For one compile, later wins: the built-in profile, the `mbuild.mettle`
profile chain, the same profile in `mbuild.local.mettle`, the bin's keys,
then `--set KEY=VALUE` on the command line. `--flag ARG` adds a raw flag.

An unknown key is a warning, a bad value an error:

```text
warning: mbuild.mettle:12: unknown key 'native-heep' in [profile.fast] (did you mean 'native-heap'?)
$ mbuild --set optimize=fast build
error: --set optimize=fast: optimize = "fast" is not one of "off", "checked", "full" (did you mean "full"?)
```

## Commands

Every top-level `fn cmd_NAME(a: MbArgs*) -> int32` is `mbuild NAME`
(`cmd_gen_docs` is `mbuild gen-docs`). It runs in the project root, gets
everything after the name untouched, and its return value is mbuild's exit
code. Global flags go before the name and reach the command only through
`mb_verbose()`.

The `//` comment block right above the function is its help: the first line
is the summary in `mbuild help` (a leading `NAME:` is dropped), the rest
shows in `mbuild help NAME`.

```text
$ mbuild help install
install - build a release and copy it into a bin directory (default ~/.local/bin)

  usage: mbuild install [ARGS...]

  mbuild install --to DIR puts it somewhere else.
From: mbuild.mettle:19 (fn cmd_install)
$ mbuild instal
error: no command named instal
  help: did you mean install? (mbuild.mettle)
```

A command named like a built-in can't be reached; `mbuild help` lists it as
`(shadowed by the built-in build; rename cmd_build)`.

### Arguments

| Call | Returns |
|---|---|
| `mb_nargs(a)` | how many arguments followed the command name |
| `mb_arg(a, i)` | argument `i` |
| `mb_flag(a, "--force")` | whether the flag is there |
| `mb_opt(a, "--out", dflt)` | the value of `--out DIR` or `--out=DIR`, else `dflt` |

### The project and the build

| Call | Returns |
|---|---|
| `mb_root()`, `mb_name()`, `mb_version()` | the project's root, package name and version |
| `mb_os()`, `mb_exe_ext()` | `"linux"` / `"windows"`, `""` / `".exe"` for the machine running mbuild |
| `mb_verbose()` | whether `-v` was given |
| `mb_out(bin, target, profile)` | absolute path of the file a bin builds: the executable, `lib<bin>.so` / `<bin>.dll`, `<bin>.o` / `<bin>.obj`, or `<bin>.bin`; a freestanding bin's is under its triple whatever `target` says |
| `mb_mbuild(args)` | runs this mbuild with `args` (split on spaces) and returns its exit code; nests at most 8 deep |

### Processes and files

| Call | Does |
|---|---|
| `mb_cmd(program)` | a command to run, found on PATH; it belongs to mbuild, so don't free it |
| `mb_cmd_arg(c, s)`, `mb_cmd_cwd(c, dir)`, `mb_cmd_env(c, "NAME=value")` | add an argument, set its directory, set a variable for it only |
| `mb_cmd_run(c)` | runs it with your terminal, returns the exit code (127: could not start) |
| `mb_cmd_output(c)` | runs it, returns stdout without one trailing newline; the exit code is then `mb_cmd_status(c)` |
| `mb_sh(line)` | runs a line through `sh -c` (Linux) or `cmd /c` (Windows) |
| `mb_spawn(c)` | starts it in the background, output to `.mbuild/logs/PROGRAM.log` (`mb_proc_log(p)`); returns an `MbProc*` |
| `mb_proc_running(p)`, `mb_proc_code(p)`, `mb_stop(p)` | still running?; its exit code once it isn't; terminate it (killed after 2 s) |
| `mb_wait_port(port, ms)` | true once `127.0.0.1:port` accepts a connection, false after `ms` |
| `mb_env(name)`, `mb_home()` | an environment variable, the home directory |
| `mb_exists(p)`, `mb_is_dir(p)` | |
| `mb_read(p)` | the file's content, `""` when unreadable |
| `mb_write(p, data)` | writes it, creating parent directories |
| `mb_write_if_changed(p, data)` | the same, only when the content differs; true when it wrote |
| `mb_copy(src, dst)` | copies a file, keeping the executable bit |
| `mb_mkdirs(p)`, `mb_remove(p)` | `mb_remove` takes a file or a whole directory |
| `mb_say(s)`, `mb_warn(s)`, `mb_fail(s)` | prints to stdout; `warning: s` on stderr; `error: s` on stderr and exit 1 |

Relative paths are relative to the project root. What a command or hook
starts with `mb_spawn` and doesn't stop is stopped when it returns.

## mbuild shell

`mbuild shell [BIN] [--plain] [-- ARGS]` builds the program with `--live`,
starts it and gives you a shell inside it. The program opts in with one call
next to its `quiesce;`:

```mettle
import "mbuild/shell";

  while (running) {
    quiesce;
    shell_point();
    step();
  }
```

Outside `mbuild shell` the import is an empty `shell_point()`, so the code
builds everywhere. Each input runs once at the next `shell_point()`:

| input | does |
|---|---|
| `world.pop + 1` | prints the value; a struct prints field by field |
| `world.food = 1000;` | runs the statement, prints `ok` |
| `fn harvest(pop: int32) -> int32 { ... }` | redefines `harvest` in the running program |
| `edit NAME` | `NAME`'s current source in `$EDITOR` (vi), patched in when it changed |
| `undo [NAME]` | takes back the last change, or `NAME`'s last redefinition |
| `r` | patches in the files on disk (redefinitions dropped) |
| `pause`, `resume`, `step` | stop at the next `shell_point()`, go on, run one tick and stop again |
| `pause when EXPR` | pause at the `shell_point()` where the bool EXPR turns true; no EXPR clears it |
| `status` | running or paused, the tick (`shell_point()` calls), patches, the condition |
| `watch [EXPR]`, `unwatch EXPR` | add EXPR to the values written at every tick (the globals are there from the start); no EXPR lists them |
| `ls [FILE]` | functions, globals and structs of the bin's import graph by file, each with the first line of its doc comment |
| `apropos TEXT` | the same lines for names and doc comments containing TEXT, any case |
| `explain NAME` (`h NAME`) | a function's signature, doc and file:line; a global's type, doc and current value; a struct's fields with their comments |
| `i EXPR` | type, and the fields of a struct |
| `:log [N]` / `:unmute` / `:mute` | the program's last N output lines (20) / stream its output above the prompt / hold it again |
| `help` | every command, grouped, with an example each |
| `:q`, Ctrl-D | quit; the program stops too |

While paused, `shell_point()` waits on the thread that called it, taking
patches and running inputs, so the state is the one between two ticks; the
program's other threads keep running.

On a terminal the session is full screen: mbuild runs `mbuild-shell` (beside
the mbuild binary; `mbuild install` puts it there, a source checkout builds
it on demand), which starts `mbuild shell --serve` on two FIFOs in
`.mbuild/shell` and draws it with `lib/tui`, a small terminal library in
Mettle. A header and a footer show running/paused, the tick and the patches;
the input sits between two rules with history and tab completion; `/` opens
a command palette; `ctrl+p` pauses or resumes, `ctrl+n` steps, `ctrl+o`
streams the program's output into the scrollback, `ctrl+d` quits. Views
(Esc back): `/inspect EXPR` (a tree: Enter expands a struct or pointer, `e`
sets a field), `/code [NAME]` (functions and structs, patched ones marked,
the source with what each patch replaced; `e` edits in `$EDITOR`, `u`
undoes, `h` history), `/watch` (live values; `a` adds, `d` removes), `/log`.
Without mbuild-shell, piped, or with `--plain`, it is the line shell.

In line mode the program's stdout and stderr are held: a dim
`(N new lines held, :log)` before a prompt says how many arrived, `:log`
shows them. `:unmute` (or `mbuild shell --stream`) prints them above the
prompt instead, and the line being typed is drawn again under them. When the
program exits, its last 5 lines and its exit code print and the shell ends.
Tab completes names and commands, Ctrl-C clears the line. Globals and
functions of every module are in scope; locals of running functions are not. Redefinitions go to a copy of the sources in
`.mbuild/shell/tree`, never to `src/`. An input that doesn't answer within
5 seconds (`MBUILD_SHELL_TIMEOUT`, ms) means the program never reached
`shell_point()`. `mbuild shell --local` runs no program: each input is built
into a small one that imports what the entry imports, and `var` statements
are replayed before each input. Linux only for now; [the example](../examples/live)
has a capture.

## Live preview

`mbuild live` and `mbuild shell` tell the running program what happens
around it, so a preview window (a renderer, a game) can reload assets and
show errors without polling the disk itself. In `fn project()`:

```mettle
  mb_watch("shaders/**, assets/*.png");   // globs from the root; calls add up
  mb_preview("right");                     // left, right, top, bottom or off
```

mbuild polls the `mb_watch` files every 150 ms beside the code `mettle live`
already patches, and appends events to `.mbuild/live/BIN.events` (emptied at
start, its absolute path in `MBUILD_LIVE_EVENTS`). Each event is one whole
UTF-8 line written at once: the kind, then one space and the payload to the
end of the line, or the kind alone.

| line | when |
|---|---|
| `changed PATH`, `removed PATH` | a watched file (from the root) was added or changed, or went |
| `patched NAME` | a function was patched in, a line each (`mettle live`, or a shell input) |
| `patch-error MSG` | a patch did not compile: `FILE:LINE:COL: message` of the first error |
| `built`, `build-error MSG` | the first build worked, or didn't; `built` also ends a save that compiled and patched nothing |
| `paused`, `resumed` | `mbuild shell`: pause, resume, step |
| `exited CODE` | the program ended |

Every save of the program's source files ends with `patched` lines, `built`
or `patch-error`, once. `mettle live` loses a save made while it patches, so
mbuild counts the saves too, and one left unanswered for 2 s is answered by
the compiler's check of the entry.

Readers skip kinds they don't know. `--preview SIDE` (either command) sets
`MBUILD_PREVIEW` for the program, overriding `mb_preview`; mbuild does
nothing else with it. The program reads the events with `mbuild/live`:

```mettle
import "mbuild/live";

  var ev: MbLiveEvent;         // kind, path (changed/removed), detail (the rest)
  while (mblive_next(&ev)) {   // one read when nothing is buffered: call it every frame
    if (ev.kind == "changed") { reload(ev.path); }
  }
```

`mblive_active()` says whether the variable is set. Elsewhere it isn't, so
`mblive_next` answers false after one `getenv` and the code builds and runs
everywhere. The strings stay valid until the next call. Under `mbuild live`
the program's stdout and stderr come through mbuild (to read `mettle live`'s
lines), so they are pipes, not the terminal. A program printing each event it
reads, while `shaders/a.glsl` is saved, `shaders/b.glsl` removed and
`val` edited, broken and fixed:

```text
$ mbuild live
        Live fx (linux, debug)
Built executable '.../build/linux/debug/live/fx'
active true preview=right
ev built||
ev changed|shaders/a.glsl|
ev removed|shaders/b.glsl|
Patch 1: val (320 bytes)
ev patched||val
-- .../src/rules.mettle:2:13
error[E0002]: Expected an expression after '+', found ';'
...
ev patch-error||src/rules.mettle:2:13: Expected an expression after '+', found ';'
Patch 2: val (320 bytes)
ev patched||val
$ cat .mbuild/live/fx.events
built
changed shaders/a.glsl
removed shaders/b.glsl
patched val
patch-error src/rules.mettle:2:13: Expected an expression after '+', found ';'
patched val
```

Changes found in one poll come in path order. On Windows `mbuild live` passes
only `MBUILD_PREVIEW` for now.

## Hooks

`fn hook_pre_build() -> int32` runs once per target and profile of every
command that compiles (`build`, `run`, `check`, `test`, `live`), after
dependencies are ready and before mbuild decides what is Fresh, so files it
writes are part of the build. It runs every time; write with
`mb_write_if_changed` and an unchanged build stays Fresh.

`fn hook_post_build() -> int32` runs once per target and profile after the
bins are linked (`build`, `run`, `live`), also when everything was Fresh;
for `live`, once after its first build, before the program starts.

Inside a hook, `mb_target()`, `mb_profile_name()` and `mb_out_dir()` say what
is being built, `mb_bins()` lists the bins and `mb_built()` the ones that were
actually compiled (space-separated):

```mettle
fn hook_post_build() -> int32 {
  mb_say("built: [" + mb_built() + "] for " + mb_target() + " " + mb_profile_name());
  return 0;
}
```

```text
$ mbuild build
   Compiling viewer (linux, debug)
built: [viewer] for linux debug
    Finished in 0.0s
$ mbuild build
       Fresh viewer (linux, debug)
built: [] for linux debug
    Finished in 0.0s
```

A non-zero return fails the command:
`error: hook_post_build failed (exit 2) for linux debug`. `--no-hooks` skips
both. Only your project's hooks run, never a dependency's.

## mbuild.local.mettle

Settings for this machine only go in `mbuild.local.mettle`, beside
`mbuild.mettle`. `mbuild init` gitignores it and `mbuild publish` never packs
it. It defines `fn local()`:

```mettle
import "mbuild/api";

fn local() {
  mb_replace_path("strutil", "../strutil");             // work on a dependency in place
  mb_use("logger", "quiet");                            // a component impl (mbuild use writes this)
  mb_tool("cc", "clang");                               // instead of $CC
  mb_tool("mettle-windows", "/home/me/win/mettle.exe"); // instead of $MBUILD_METTLE_WINDOWS
  mb_registry("default", "file:///srv/mettle-mirror");  // a mirror
  mb_targets("linux");
  mb_profile("debug");
  mb_set("safe", "true");
}
```

Allowed there: `mb_replace_path`, `mb_replace_version`, `mb_tool`,
`mb_registry`, `mb_use`, `mb_targets`, `mb_profile`, `mb_on`, `mb_set`,
`mb_set_list`. Anything else is an error:

```text
error: mbuild.local.mettle:2: [dependencies] is not allowed here (mbuild.local.mettle holds [replace], [tools], [profile.NAME], [build] targets, [components] and [registry.NAME] url)
```

Like `fn project()`, `fn local()` can't read the environment or files.

`mb_tool` names: `cc`, `cc-windows`, `mettle-linux`, `mettle-windows`,
`pkg-config`. A tool applies only when its environment variable (`CC`,
`CC_WINDOWS`, `MBUILD_METTLE_LINUX`, `MBUILD_METTLE_WINDOWS`, `PKG_CONFIG`) is
unset, and `mettle-<os>` also only without `--mettle` and `$METTLE`; it beats
the project's `mb_toolchain`. `mbuild doctor` and `mbuild toolchain` show
where each came from.

Replacements here never touch `mbuild.lock`; the resolved versions go to
`.mbuild/local.lock` instead, and every command says so:

```text
$ mbuild run
note: using replacements from mbuild.local.mettle (strutil); mbuild.lock is left as it is
   Resolving dependencies
    Removing strutil v1.1.0
...
$ mbuild deps
note: using replacements from mbuild.local.mettle (strutil); mbuild.lock is left as it is
strutil => ../strutil (replaced) (local)
```

Delete the line and the next build goes back to the lock.

## mbuild init

`mbuild init [NAME]` writes `mbuild.mettle` (package named after the
directory, with an example `cmd_hello`), a hello world `src/main.mettle`
unless there's already a main file, and these `.gitignore` lines:
`/build/`, `/.mbuild/`, `/mettle.deps`, `/mbuild.local.mettle`. Lines of a
hand-written `mettle.deps` become `mb_dep_path` calls.

`mbuild init --package` and `mbuild init --from PKG` are in
[packages](packages.md).

## Files mbuild writes

| Path | What | Commit it? |
|---|---|---|
| `mbuild.lock` | exact versions and sha256 of every package | yes |
| `AGENT.rules` | a block pointing at your dependencies' rules (yours outside it) | yes |
| `mettle.deps` | the compiler's package map, so plain `mettle` and editors find packages; regenerated every build | no |
| `build/` | outputs | no |
| `.mbuild/` | extracted packages, caches, stamps, generated files | no |

`mbuild clean` removes `build/`, the C cache, `.mbuild/stamps`, `.mbuild/tmp`
and `.mbuild/dep-bins`. `mbuild clean --all` removes all of `.mbuild/` too;
packages come back from the download cache in `$MBUILD_HOME`, which `clean`
never touches.
