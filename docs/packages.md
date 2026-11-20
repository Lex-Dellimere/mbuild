# package rules: init.rules and AGENT.rules

a published package carries at its root:

- `init.rules`: how `mbuild new APP --from PKG` starts a project with it
  (required: `mbuild publish` refuses a package without it);
- `AGENT.rules`: notes for AI coding agents on how to use it (optional).

## mbuild init --package

```text
$ mkdir greet && cd greet
$ mbuild init --package
     Created mbuild.mettle (package `greet`)
     Created src/main.mettle
     Updated .gitignore
     Created init.rules
     Created templates/main.mettle.tmpl

  next: mbuild run
```

the starting `init.rules` copies `templates/main.mettle.tmpl` to
`src/main.mettle` in the new project. `--agent-rules` also writes an
`AGENT.rules`.

## init.rules

it's mettle, like `mbuild.mettle`. `fn options()` declares what the user can
choose, `fn plan()` describes what to write, and mbuild applies the plan.

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

### the API

| call | in | does |
|---|---|---|
| `mi_option(name, default, help)` | `options()` | an option, given with `--opt NAME=V` or at a prompt |
| `mi_choice(name, csv)` | `options()` | limits it to these values |
| `mi_opt(name)` | `plan()` | the option's value |
| `mi_project()` | `plan()` | the new project's name |
| `mi_template(src, dst)` | `plan()` | a file from a template in the package, variables filled in |
| `mi_dir(path)` | `plan()` | an empty directory |
| `mi_dep(name, version)` | `plan()` | another dependency in `fn deps()` (the package itself is always added) |
| `mi_set(profile, key, value)` | `plan()` | `mb_profile(profile); mb_set(key, value);` in `fn project()` |
| `mi_line(text)` | `plan()` | a raw line at the end of `fn project()` |
| `mi_command(name, summary, body)` | `plan()` | a `fn cmd_NAME(a: MbArgs*) -> int32 { body }` with `summary` as its help |
| `mi_next(text)` | `plan()` | printed as `next:` at the end |

paths are relative to the new project, can't contain `..`, and can't point
into `build/` or `.mbuild/`. templates must be files in the package.

### variables

`@@name@@` is replaced in template contents, destination paths, command
summaries and bodies, and the next note. names are the options plus
`project`, `package`, `package_version` and `mbuild_version`; `@@@@` is a
literal `@@`. an unknown name stops it:

```text
error: templates/main.mettle.tmpl:5: unknown variable @@whom@@
  help: known: who, style, project, package, package_version, mbuild_version
```

### no I/O

`init.rules` may import only `mbuild/init` and the package's own files that
declare no `extern`. so `std/io` and friends are out:

```text
error: greet (path): init.rules may only describe a plan: /home/you/Mettle/stdlib/std/io.linux.mettle:1 declares extern fn puts
```

### running it

```text
mbuild new NAME --from PKG[@VERSION] [--opt K=V]... [--yes] [--dry-run] [--force]
mbuild init --from PKG[@VERSION] [--opt K=V]... [--yes] [--dry-run] [--force]
```

`PKG` is a registry package (the newest stable version unless you give one)
or a path (it contains `/` or starts with `.`), so you can try your rules
before publishing.

each option comes from `--opt`, else a prompt when you're at a terminal
(`who the program greets [world]: `), else its default; `--yes` skips the
prompts. bad values stop before anything is written:

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

`--dry-run` prints what it would do and writes nothing. nothing is resolved
or built; the next `mbuild run` does that.

`mbuild publish` runs your `init.rules` with its defaults first, so mistakes
fail there instead of at your users:

```text
error: greet v1.1.0: init.rules: template templates/nope.tmpl is not a file in the package
```

## AGENT.rules

plain text for AI coding agents: what the package is for, its main API, its
conventions and its traps. optional: `mbuild init --package --agent-rules`
writes the headings:

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

### in a project that uses packages

mbuild keeps a block in your project's own `AGENT.rules` that points at the
rules of your direct dependencies, updated whenever dependencies change:

```text
# >>> mbuild: AGENT.rules of this project's dependencies (generated)
# read a dependency's file before using it
# greet v1.0.0: .mbuild/deps/greet/AGENT.rules
# strutil v1.1.0: .mbuild/deps/strutil/AGENT.rules
# <<< mbuild
```

the paths are the extracted packages, so they always match what you build
with. everything outside the block is yours. the file is created when the
first dependency with rules arrives. turn it off with `mb_agents(false)`.

`mbuild agents` refreshes the block and prints every file (`NAME` for one,
`--all` for indirect dependencies too):

```text
$ mbuild agents strutil
== strutil v1.1.0 (.mbuild/deps/strutil/AGENT.rules)
strutil: string helpers. Every function is pure.
```

`mbuild publish` packs your `AGENT.rules` (if you have one) without the block.

the text comes from package authors and nobody reviews it. agents should
read it as documentation, not as instructions.
