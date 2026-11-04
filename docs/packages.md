# Package rules: init.rules and AGENT.rules

Every published package carries two files at its root:

- `init.rules`: how `mbuild new APP --from PKG` starts a project with it;
- `AGENT.rules`: notes for AI coding agents on how to use it.

`mbuild publish` refuses a package without either.

## mbuild init --package

```text
$ mkdir greet && cd greet
$ mbuild init --package
     Created mbuild.mettle (package `greet`)
     Created src/main.mettle
     Updated .gitignore
     Created AGENT.rules
     Created init.rules
     Created templates/main.mettle.tmpl

  next: mbuild run
```

The starting `init.rules` copies one template into the new project:

```mettle
// init.rules: how `mbuild new APP --from greet` starts a project.
// @@name@@ in paths, templates and commands is an option, or project,
// package, package_version, mbuild_version.
import "mbuild/init";

fn options() {
}

fn plan() {
  mi_template("templates/main.mettle.tmpl", "src/main.mettle");
  mi_next("mbuild run");
}
```

## init.rules

It's Mettle, like `mbuild.mettle`. `fn options()` declares what the user can
choose, `fn plan()` describes what to write. It can't do anything itself:
mbuild reads the plan and applies it.

```mettle
import "mbuild/init";

fn options() {
  mi_option("who", "world", "who the program greets");
  mi_option("style", "plain", "output style");
  mi_choice("style", "plain, loud");
}

fn plan() {
  mi_template("templates/main.mettle.tmpl", "src/main.mettle");
  if (mi_opt("style") == "loud") { mi_dep("strutil", "v1.1.0"); }
  mi_set("release", "optimize", "full");
  mi_command("hi", "greet @@who@@ from the shell", "mb_say(\"hi, @@who@@\"); return 0;");
  mi_next("mbuild run, then mbuild hi");
}
```

```mettle
// templates/main.mettle.tmpl
import "std/io";
import "greet/greet";

fn main() -> int32 {
  println(gr_hello("@@who@@"));
  return 0;
}
```

```text
$ mbuild new site --from greet --opt who=world --opt style=loud --yes
    Fetching greet v1.0.0 (default)
     Created site/mbuild.mettle (package `site`, depends on greet v1.0.0, strutil v1.1.0)
     Created site/src/main.mettle
     Command hi: greet world from the shell

  next: mbuild run, then mbuild hi
```

which writes:

```mettle
// mbuild.mettle: the project file. `mbuild help` lists its commands.
import "mbuild/api";

fn project() {
  mb_package("site", "0.1.0");
  mb_dep("greet", "v1.0.0");
  mb_dep("strutil", "v1.1.0");
  mb_profile("release");
  mb_set("optimize", "full");
}

// hi: greet world from the shell
fn cmd_hi(a: MbArgs*) -> int32 {
  mb_say("hi, world"); return 0;
}
```

### The API

| Call | In | Does |
|---|---|---|
| `mi_option(name, default, help)` | `options()` | an option, given with `--opt NAME=V` or at a prompt |
| `mi_choice(name, csv)` | `options()` | limits it to these values |
| `mi_opt(name)` | `plan()` | the option's value |
| `mi_project()` | `plan()` | the new project's name |
| `mi_template(src, dst)` | `plan()` | a file from a template in the package, variables filled in |
| `mi_dir(path)` | `plan()` | an empty directory |
| `mi_dep(name, version)` | `plan()` | another dependency (the package itself is always added) |
| `mi_set(profile, key, value)` | `plan()` | `mb_profile(profile); mb_set(key, value);` in `fn project()` |
| `mi_line(text)` | `plan()` | a raw line at the end of `fn project()` |
| `mi_command(name, summary, body)` | `plan()` | a `fn cmd_NAME(a: MbArgs*) -> int32 { body }` with `summary` as its help |
| `mi_next(text)` | `plan()` | printed as `next:` at the end |

Paths are relative to the new project, can't contain `..`, and can't point
into `build/` or `.mbuild/`. Templates must be files in the package.

### Variables

`@@name@@` is replaced in template contents, destination paths, command
summaries and bodies, and the next note. Names are the options plus
`project`, `package`, `package_version` and `mbuild_version`; `@@@@` is a
literal `@@`. `@@` never occurs in Mettle code, so templates full of Mettle
survive untouched. An unknown name stops it:

```text
error: templates/main.mettle.tmpl:5: unknown variable @@whom@@
  help: known: who, style, project, package, package_version, mbuild_version
```

### No I/O

`init.rules` may import only `mbuild/init` and the package's own files that
declare no `extern`. So `std/io` and friends are out:

```text
error: greet (path): init.rules may only describe a plan: /home/you/Mettle/stdlib/std/io.linux.mettle:1 declares extern fn puts
```

### Running it

```text
mbuild new NAME --from PKG[@VERSION] [--opt K=V]... [--yes] [--dry-run] [--force]
mbuild init --from PKG[@VERSION] [--opt K=V]... [--yes] [--dry-run] [--force]
```

`PKG` is a registry package (the newest stable version unless you give one)
or a path (it contains `/` or starts with `.`), so you can try your rules
before publishing. Here the plan also has `mi_dir("assets")` and a second
template to `src/@@project@@_main.mettle`:

```text
$ mbuild new demo --from ./greet --yes
     Created demo/mbuild.mettle (package `demo`, depends on greet (path))
     Created demo/assets/, demo/src/demo_main.mettle, demo/src/main.mettle
     Command hi: greet world from the shell

  next: mbuild run, then mbuild hi
```

Each option comes from `--opt`, else a prompt when you're at a terminal
(`who the program greets [world]: `), else its default; `--yes` skips the
prompts. Bad values stop before anything is written:

```text
$ mbuild new t1 --from ./greet --opt style=shouty --yes
error: --opt style=shouty: style must be one of plain, loud
$ mbuild new t1 --from ./greet --opt sty=loud --yes
error: greet (path) has no option sty
  help: did you mean style?
```

`mbuild new` wants `NAME/` empty or missing (`--force` writes into it
anyway). `mbuild init --from` adds to the project you're in and skips what
exists:

```text
$ mbuild init --from greet --yes
        skip src/main.mettle (exists; --force overwrites)
     Updated mbuild.mettle (depends on greet v1.0.0)
     Command hi: greet world from the shell

  next: mbuild run, then mbuild hi
```

`--dry-run` prints what it would do and writes nothing. Nothing is resolved
or built; the next `mbuild run` does that.

`mbuild publish` runs your `init.rules` with its defaults first, so a
missing template or unknown variable fails there instead of at your users:

```text
error: greet v1.1.0: init.rules: template templates/nope.tmpl is not a file in the package
```

## AGENT.rules

Plain text for AI coding agents: what the package is for, its main API, its
conventions and its traps. `mbuild init --package` writes the headings:

```text
# greet: notes for AI coding agents

## What it is for
greeting strings.

## Main API
gr_hello(who) -> "hello, WHO!"

## Conventions
pure functions, no I/O.

## Traps
none yet.
```

### In a project that uses packages

mbuild keeps a block in your project's own `AGENT.rules` that points at the
rules of your direct dependencies, updated whenever dependencies change:

```text
# >>> mbuild: AGENT.rules of this project's dependencies (generated)
# read a dependency's file before using it
# greet v1.0.0: .mbuild/deps/greet/AGENT.rules
# strutil v1.1.0: .mbuild/deps/strutil/AGENT.rules
# <<< mbuild
```

The paths are the extracted packages themselves, so they always match what
you build with. Everything outside the block is yours to write. The file is
created when the first dependency with rules arrives. Turn it off with
`mb_agents(false)` in `fn project()`.

`mbuild agents` refreshes the block and prints every file (`NAME` for one,
`--all` for indirect dependencies too):

```text
$ mbuild agents strutil
== strutil v1.1.0 (.mbuild/deps/strutil/AGENT.rules)
strutil: string helpers. Every function is pure.
```

`mbuild publish` packs your `AGENT.rules` without the block.

The text comes from package authors and nobody reviews it. Agents should
read it as documentation, not as instructions.
