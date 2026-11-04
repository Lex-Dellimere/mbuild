# Components and runtime options

A component is an interface with several implementations, one file each.
Your code imports the component by name and mbuild wires in an
implementation:

- `static`: one impl is picked at build time, the others aren't compiled;
- `dyn`: every impl is linked and the program picks one at run time;
- `swap`: every impl is linked and the program can switch while it runs.

## static

```text
src/logger/stdout.mettle
src/logger/quiet.mettle
```

```mettle
// src/logger/stdout.mettle
import "std/io";

export fn log_line(s: string) {
  println("log: " + s);
}
```

```mettle
// src/logger/quiet.mettle
export fn log_line(s: string) {
}
```

```mettle
// src/main.mettle
import "std/io";
import "logger";

fn main() -> int32 {
  log_line("starting");
  println("logger = " + LOGGER_IMPL);
  return 0;
}
```

```mettle
fn project() {
  mb_package("comp", "0.1.0");
  mb_component("logger", "src/logger", "static", "stdout, quiet");

  mb_profile("release");
  mb_use("logger", "quiet");
}
```

```text
$ mbuild run
   Compiling comp (linux, debug)
    Finished in 0.0s
     Running build/linux/debug/comp
log: starting
logger = stdout
$ mbuild -r run
   Compiling comp (linux, release)
    Finished in 0.0s
     Running build/linux/release/comp
logger = quiet
```

`mb_component(name, dir, mode, impls)`: each impl is `<dir>/<impl>.mettle`
(it may import siblings, so shared code can go in `<dir>/common.mettle`).
The first impl is the default and defines the interface: every other impl
must export the same names with the same signatures, extra exports are
fine. `NAME_IMPL` (`LOGGER_IMPL` here) holds the chosen impl's name.

```text
$ mbuild -r build
error: component logger: impl quiet does not match stdout: missing fn log_flush() -> int32 (src/logger/stdout.mettle:6)
```

Only the selected impl is compiled, so `mbuild components --check` compiles
every impl to catch the ones you aren't using:

```text
$ mbuild components --check
    Checking logger = stdout
    Checking logger = quiet
     Checked 2 static impls, every component's interface
```

A component name is a single import component, so it's never mistaken for
a package. Names must be unique across your project and its dependencies.

## Which impl is used

Later wins:

1. the first impl in the list;
2. `mb_component_on(name, os, impl)`, a per-OS default;
3. `mb_use(name, impl)` in a profile (and its OS-qualified part, `mb_on`);
4. `mb_use` after `mb_for_bin(name)`;
5. `mb_use` in `mbuild.local.mettle`, written by `mbuild use`;
6. `--use NAME=IMPL` on the command line.

```text
$ mbuild components
COMPONENT  MODE    IMPLS         SELECTED (linux, debug)  FROM
logger     static  stdout quiet  stdout                   default
$ mbuild -r components
COMPONENT  MODE    IMPLS         SELECTED (linux, release)  FROM
logger     static  stdout quiet  quiet                      mbuild.mettle:8
$ mbuild --use logger=loud run
error: --use: component logger has no impl 'loud'; its impls: stdout, quiet
```

`mbuild use` picks one on this machine only:

```text
$ mbuild use logger=quiet
    Updating mbuild.local.mettle: mb_use("logger", "quiet")
       Using logger = quiet (mbuild.local.mettle)
$ mbuild use logger
    Removing mbuild.local.mettle: mb_use("logger", "quiet")
       Using logger = stdout (default)
```

Libraries can declare components; only your project chooses.

Plain `mettle` and editors don't know which impl is selected, so
`import "logger"` doesn't resolve for them. `mbuild mettle -- ARGS` runs the
compiler with the selection of a host debug build.

## dyn

Every impl is linked; the program picks one by name. The component's
directory holds `<name>.mettle` with exactly one `@dyn export trait`, and
each impl exports its struct and a constructor `<component>_<impl>_new()`:

```mettle
// src/renderer/renderer.mettle
import "std/meta";

@dyn export trait Renderer {
  fn cost(self: Self) -> int32;
}
```

```mettle
// src/renderer/ascii.mettle (fancy.mettle is the same with Fancy and 5000)
import "renderer";

export struct Ascii {
  w: int32;
}

impl Renderer for Ascii {
  fn cost(self: Self) -> int32 { return self.w; }
}

export fn renderer_ascii_new() -> Renderer__dyn {
  var a: Ascii* = new Ascii;
  a->w = 105;
  return Renderer__from_Ascii(a);
}
```

```mettle
// src/main.mettle
import "std/io";
import "renderer";

fn main() -> int32 {
  println("impls: " + renderer_impls() + ", default " + RENDERER_IMPL);
  var r: Renderer__dyn = renderer_new("fancy");
  println("fancy costs {r.cost()}");
  return 0;
}
```

```mettle
  mb_component("renderer", "src/renderer", "dyn", "ascii, fancy");
```

```text
$ mbuild run
   Compiling dyn (linux, debug)
    Finished in 0.0s
     Running build/linux/debug/dyn
impls: ascii fancy, default ascii
fancy costs 5000
```

mbuild generates `renderer_new(name)` (an unknown name gives the default),
`renderer_impls()`, `renderer_has(name)` and `RENDERER_IMPL`. `mb_use` sets
the default. The impl struct must be exported:

```text
error: component renderer (dyn): struct Fancy in src/renderer/fancy.mettle implements Renderer but is not exported; export it (`export struct Fancy`): @dyn skips an impl for a private struct of another file
```

## swap

Every impl is linked and each interface function becomes a slot. The
program stages another impl, and the switch happens at its next `quiesce;`:

```mettle
// src/policy/gentle.mettle
@swappable export fn policy_score(n: int32) -> int32 {
  return n + 1;
}
```

```mettle
// src/policy/harsh.mettle
@swappable export fn policy_score(n: int32) -> int32 {
  return n * 10;
}
```

```mettle
// src/main.mettle
import "std/io";
import "policy";

fn main() -> int32 {
  println("{policy_score(5)}");
  policy_stage("harsh");
  println("{policy_score(5)}");
  quiesce;
  println("{policy_score(5)}");
  return 0;
}
```

```mettle
  mb_component("policy", "src/policy", "swap", "gentle, harsh");
```

```text
$ mbuild run
   Compiling swap (linux, debug)
    Finished in 0.0s
     Running build/linux/debug/swap
6
6
50
```

Rules:

- every export of every impl is `@swappable export fn`, with the same
  signatures in all of them;
- parameters and results are built-in types only (integers, floats, `bool`,
  `char`, `string`, `cstring`, `rawptr` and pointers to those). Pass a struct
  as a `rawptr`:

  ```text
  error: component policy (swap): src/policy/gentle.mettle:6: fn policy_rate(m: LogMsg*) -> int32 uses the struct LogMsg; a swap component's functions take built-in types only (pass a rawptr), see DESIGN.md 15.4
  ```
- at most 256 functions per component;
- the program needs a `quiesce;` somewhere, or a staged swap never applies:

  ```text
  warning: component policy is swappable but the program has no quiesce; a staged swap never applies
  ```

`policy_stage(name)` returns false for an unknown name; `policy_impls()` and
`POLICY_IMPL` are there too.

## mbuild live

`mbuild live` builds the host target and runs the program under
`mettle live`: every file you save patches the running program at its next
`quiesce;`, and `mbuild use` in another terminal switches a component the
same way. Here `stdout.mettle` is edited after tick 2, and
`mbuild use logger=quiet` runs after tick 6:

```mettle
import "logger";

extern fn usleep(us: uint32) -> int32;

fn main() -> int32 {
  var i: int32 = 0;
  while (i < 10) {
    quiesce;
    log_line("tick {i}");
    usleep(500000);
    i = i + 1;
  }
  return 0;
}
```

```text
$ mbuild live
        Live comp (linux, debug)
Built executable '/home/you/comp/build/linux/debug/live/comp'
[live] running /home/you/comp/build/linux/debug/live/comp; saving any of its 4 source files patches it
log: tick 0
log: tick 1
log: tick 2
Patch 1: log_line (520 bytes)
[live] patch 1: 1 function
LOG: tick 3
LOG: tick 4
LOG: tick 5
LOG: tick 6
Patch 2: log_line (296 bytes)
[live] patch 2: 1 function
[live] /home/you/comp/build/linux/debug/live/comp exited with 0
```

`mbuild live [BIN] [-p PROFILE] [-- ARGS]`. The exit code is the program's.
Dependencies, C libraries, components and `hook_pre_build` are set up as for
`mbuild run`.

## Runtime options

The runtime is configured with typed settings in a profile, per bin or per
OS ([project](project.md#profiles-and-settings) has the full table):

```mettle
  mb_profile("release");
  mb_set("crash-report", "false");     // --no-crash-report
  mb_set("native-heap", "true");       // new/malloc through std/alloc
  mb_on("windows");
  mb_set("subsystem", "windows");      // no console window
  mb_on("");

  mb_profile("debug");
  mb_set("safe", "true");              // memory-safety checks
  mb_set("profile-runtime", "true");   // a function timing report at exit
```

## Bin kinds

`mb_bin_kind(name, kind, triple)`:

| kind | Output |
|---|---|
| `exe` | `build/<target>/<profile>/<bin>`, `.exe` on Windows (the default) |
| `shared` | `lib<bin>.so` / `<bin>.dll`; no `main` needed; `mbuild run` refuses it |
| `object` | `<bin>.o` / `.obj` for the triple (default: the target's), to link elsewhere |
| `flat` | `<bin>.bin`, a raw image; needs a `*-none` triple and `image-base` |

```mettle
  mb_bin("app", "src/main.mettle");
  mb_bin("plug", "src/plug.mettle");
  mb_bin_kind("plug", "shared", "");
  mb_bin("kern", "src/kern.mettle");
  mb_bin_kind("kern", "flat", "x86_64-none");
  mb_for_bin("kern");
  mb_set("image-base", "0x100000");
```

```text
$ mbuild build
   Compiling app (linux, debug)
   Compiling plug (linux, debug)
   Compiling kern (x86_64-none, debug)
Built shared library 'build/linux/debug/libplug.so'
Wrote flat image 'build/x86_64-none/debug/kern.bin' at 0x100000
    Finished in 0.0s
```

A bin with a `*-none` triple is freestanding: built once per profile into
`build/<triple>/<profile>/`, whatever `-t` says, with no runtime, so no C
code, no `swap` components, no `safe` or `stack-trace`. Running one is up to
you:

```text
$ mbuild run kern
error: bin kern is freestanding (x86_64-none): mbuild cannot run it
  help: write a project command that starts your emulator: fn cmd_qemu
```

## Project rules

`mb_rule(file)` attaches a file of `@rule` functions to every bin and test of
your project, so the compiler checks your whole program against them:

```mettle
// rules/norec.mettle
import "std/rule";

@rule fn no_recursion(p: Program) -> Verdict {
  for f in p.functions {
    if (f.is_recursive) {
      return verdict_fail(f.site, "this program forbids recursion");
    }
  }
  return verdict_pass();
}
```

```mettle
  mb_rule("rules/norec.mettle");
```

```text
$ mbuild build
   Compiling rl (linux, debug)
-- /home/you/rl/src/util.mettle:1:8
error[R0002]: rule 'no_recursion' failed: this program forbids recursion

  ----+----------------------------------------------------------------------------------
    1 |  export fn depth(n: int32) -> int32 {
      :         ^ the rule points here
    2 |    if (n <= 0) {
  ----+----------------------------------------------------------------------------------
      |  note  the rule that failed the build  /home/you/rl/rules/norec.mettle:3:7
    3 |  @rule fn no_recursion(p: Program) -> Verdict {
      :        ^^^^
  ----+----------------------------------------------------------------------------------

-----------------------------------------------------------------------------------------
  error: could not compile `.mbuild/gen/linux-debug-rl/entry.mettle` due to 1 previous error
  help: for more about this error, run `mettle explain R0002`
error: could not compile rl (linux, debug)
```

mbuild builds a small generated file that imports your main file and the
rule files, which is why the compiler names `entry.mettle`. One thing that
changes for rules: `f.module` of a function in your main file is its
absolute path, not `""`.

Rules of dependencies aren't attached; a library that wants its rules
applied imports them from its own code.
