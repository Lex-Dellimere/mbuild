# mbuild

mbuild is a build tool and package manager for [Mettle](https://github.com/The-Mettle-Project/Mettle), and it's written in mettle.

it builds mettle programs for linux and windows, from linux or from windows (or wine). packages come from a registry: a static folder of `.tar.gz` files plus an index, served from any web host or a plain directory. the project file, `mbuild.mettle`, is mettle code too, so your project's own commands and build hooks live right next to its dependencies. it only rebuilds what changed.

```bash
mbuild init
mbuild run
```

## what it does

- builds linux binaries and windows `.exe` files (on linux through wine)
- deps from a registry, pinned by version and sha256 in `mbuild.lock`. `mbuild publish` puts your package in one
- spots imports you didn't declare and adds them for you
- `cmd_*` functions in `mbuild.mettle` become `mbuild NAME` commands, `hook_pre_build` / `hook_post_build` run around builds
- components: swap one implementation of an interface for another at build time, at run time, or while the program runs
- `mbuild new app --from somepkg` starts a project from a package's `init.rules`
- packages can ship an `AGENT.rules` for AI coding agents, and mbuild points your agent at your deps' ones
- C code in packages gets built into a `.so` / `.dll` and linked in, on both platforms
- incremental: unchanged programs are "Fresh", C files only recompile when they or their headers change, passing tests are cached

## install

mbuild needs a mettle compiler built from the mettle source (the v0.17.0 release and older can't build current projects). build it (`make` in a clone of [Mettle](https://github.com/The-Mettle-Project/Mettle)), then point `METTLE` at its `bin/mettle` for the bootstrap.

get mbuild with `git clone https://github.com/Lex-Dellimere/mbuild.git`. it builds itself: with no mbuild around yet, one plain mettle command makes a throwaway one, and that builds and installs the real thing:

```bash
cd mbuild
mettle --build src/main.mettle -o mbuild0
./mbuild0 install --from ../Mettle    # build/linux/release/mbuild into ~/.local/bin, then mbuild setup
```

or `./mbuild0 build -r -t host` and then `./build/linux/release/mbuild install --from ../Mettle`. same on windows with `mettle.exe` and `mbuild0.exe`.

`install` copies the release into `~/.local/bin` (`--to DIR` for elsewhere) and runs `mbuild setup`: it creates `~/.mbuild` (`%LOCALAPPDATA%\mbuild` on windows; `--home DIR` for elsewhere), installs the compiler (`--from DIR` builds your checkout; without it, the latest release), checks curl, tar, gcc and wine, and prints the line to add to your shell rc if mbuild isn't on PATH. see [docs/platforms.md](docs/platforms.md#toolchains).

### shell completion

`mbuild completion bash|zsh|fish` prints a completion script for commands, flags and values (this project's bins, tests, dependencies, components and profiles, the targets, and package names from the cached registry indexes, never the network):

```bash
mbuild completion bash > ~/.local/share/bash-completion/completions/mbuild
mbuild completion zsh > ~/.zsh/completions/_mbuild            # a directory in $fpath
mbuild completion fish > ~/.config/fish/completions/mbuild.fish
```

the scripts ask `mbuild __complete KIND [PREFIX]` for the values, which is also how to see what they offer:

```text
$ mbuild __complete bins
app
tool
$ mbuild __complete deps t
textkit
```

the default registry is the Mettle project's, https://the-mettle-project.github.io/Mettle/registry/. point mbuild elsewhere with `MBUILD_REGISTRY` (a URL or a directory) or declare more in `mbuild.mettle`. the transcripts here and in docs/ use the fixture registry from `sh tests/fixtures/make-registry.sh DIR`.

## a quick tour

### new project

```text
$ mkdir hello && cd hello
$ mbuild init
     Created mbuild.mettle (package `hello`)
     Created src/main.mettle
     Updated .gitignore

  next: mbuild run
$ mbuild run
   Compiling hello (linux, debug)
    Finished in 0.0s
     Running build/linux/debug/hello
Hello from hello!
```

run it again without changing anything and it prints `Fresh hello (linux, debug)` instead of compiling.

### adding a dependency

just import it. a package import is `NAME/FILE`:

```mettle
import "std/io";
import "strutil/strutil";

fn main() -> int32 {
  println(su_shout("hi"));
  return 0;
}
```

```text
$ mbuild run
      Adding strutil v1.1.0 (registry default)
      Adding mbuild.mettle: mb_dep("strutil", "v1.1.0")
   Resolving dependencies
    Fetching strutil v1.1.0 (default)
     Updated AGENT.rules
   Compiling hello (linux, debug)
    Finished in 0.0s
     Running build/linux/debug/hello
hi!
```

`mbuild.mettle` now has the dependency and `mbuild.lock` has the exact version and its sha256. or by hand:

```bash
mbuild get strutil@v1.0.0
mbuild update
mbuild remove strutil
mbuild deps --tree
```

### mbuild.mettle

the project file is mettle. `fn project()` describes the package, `fn deps()` its dependencies, every `cmd_NAME` is a command, the comment above it is its help:

```mettle
import "mbuild/api";

fn project() {
  mb_package("viewer", "0.3.0");

  mb_profile("release");
  mb_set("crash-report", "false");
}

fn deps() {
  mb_dep("strutil", "v1.1.0");
}

// install: build a release and copy it into a bin directory (default ~/.local/bin)
fn cmd_install(a: MbArgs*) -> int32 {
  var dir: string = mb_opt(a, "--to", mb_home() + "/.local/bin");
  if (mb_mbuild("build -r -t host") != 0) { return 1; }
  mb_mkdirs(dir);
  var dst: string = dir + "/viewer" + mb_exe_ext();
  if (!mb_copy(mb_out("viewer", mb_os(), "release"), dst)) { mb_fail("cannot copy to " + dst); }
  mb_say("installed " + dst);
  return 0;
}
```

```text
$ mbuild install --to ~/bin
   Compiling viewer (linux, release)
    Finished in 0.0s
installed /home/you/bin/viewer
```

machine-only settings (a local checkout of a dep, another C compiler) go in `mbuild.local.mettle`, which `mbuild init` gitignores. the whole API is in [docs/project.md](docs/project.md).

### starting from a package

a package can ship an `init.rules` that sets up a project for you:

```text
$ mbuild new site --from greet --opt who=world --yes
    Fetching greet v1.0.0 (default)
     Created site/mbuild.mettle (package `site`, depends on greet v1.0.0)
     Created site/src/main.mettle
     Command hi: greet world from the shell

  next: mbuild run, then mbuild hi
```

without `--yes` it asks for each option. `mbuild init --from greet` does the same in the project you're in. see [docs/packages.md](docs/packages.md).

### windows from linux

```bash
mbuild build -t windows
mbuild run -t windows      # runs the .exe through wine
mbuild build -t all        # both
```

this needs wine and a windows build of the mettle compiler: set `MBUILD_METTLE_WINDOWS`, or put `mb_tool("mettle-windows", PATH)` in `mbuild.local.mettle`. see [docs/platforms.md](docs/platforms.md).

## commands

| command | what it does |
|---|---|
| `mbuild init` | new project in this folder (`--package` for a publishable one, `--from PKG` for a package's starter files) |
| `mbuild new NAME --from PKG` | new project in `NAME/` from a package's `init.rules` |
| `mbuild build` | build the programs (`-r` release, `-t linux\|windows\|all`) |
| `mbuild run` | build and run (`-- args` go to the program), with its `mb_service` processes around it |
| `mbuild services` | list the processes `mbuild run` starts |
| `mbuild live` | run the program and patch it as you save |
| `mbuild shell` | a prompt inside the running program: read and set its state, redefine functions |
| `mbuild test` | run `@test` functions, cached |
| `mbuild check` | type check without linking |
| `mbuild clean` | remove build output |
| `mbuild search [TEXT]` | find packages in the registries by name, description or function |
| `mbuild info PKG[@VERSION]` | a package: README intro, versions, dependencies, every exported function with its comment |
| `mbuild get` / `remove` / `update` / `tidy` | manage deps |
| `mbuild deps` / `why` / `outdated` | show the deps, why one is there, what's newer |
| `mbuild fetch` / `vendor` | download everything so builds work offline / copy deps into `vendor/` |
| `mbuild publish` | put this package in a registry |
| `mbuild yank NAME@VERSION` | mark a published version so nothing new picks it |
| `mbuild registry init DIR` | make an empty registry |
| `mbuild components` | show which impl each component uses |
| `mbuild use NAME=IMPL` | pick a component impl on this machine |
| `mbuild agents` | show your deps' `AGENT.rules` |
| `mbuild profiles` | show the build settings per profile |
| `mbuild doctor` | check tools, compilers and externs |
| `mbuild toolchain` | install, pin and update compilers; show which builds each target |
| `mbuild setup` | set up `~/.mbuild`, a compiler and PATH |
| `mbuild completion SHELL` | print a bash, zsh or fish completion script |
| `mbuild mettle -- ...` | run the selected compiler |
| `mbuild trace` / `explain` | the mettle subcommands, inside the project |
| `mbuild NAME` | a `cmd_NAME` from your `mbuild.mettle` |

flags that work everywhere: `-v` (show every command), `-q`, `--offline`, `--locked` (for CI: fail instead of changing `mbuild.mettle` or the lock), `-j N`, `--force`, `--use NAME=IMPL`, `--set KEY=VALUE`, `--no-hooks`.

`mbuild.toml` is no longer read. `mbuild init` next to one writes an `mbuild.mettle` and leaves the old file for you to delete.

## docs

- [docs/project.md](docs/project.md): `mbuild.mettle`, commands, hooks, profiles, `mbuild.local.mettle`
- [docs/dependencies.md](docs/dependencies.md): registries, versions, the lock, publishing
- [docs/components.md](docs/components.md): swappable components, runtime options, project rules
- [docs/packages.md](docs/packages.md): `init.rules` and `AGENT.rules` for package authors
- [docs/native.md](docs/native.md): C code and C libraries
- [docs/platforms.md](docs/platforms.md): linux, windows, wine, compilers, env vars
- [docs/incremental.md](docs/incremental.md): what triggers a rebuild
- [examples/live](examples/live): a program you patch while it runs, crashes included

## building and testing mbuild itself

bootstrap as in [install](#install), then:

```bash
sh tools/mcheck.sh src/main.mettle         # debug and --release builds, zero warnings
sh tests/run.sh                            # mcheck plus every tests/e2e suite
sh tests/run.sh deps native                # just those suites
```

on linux, child processes run on [alph](https://github.com/Lex-Dellimere/Alph), vendored in `third_party/alph` (apache-2.0; `mbuild vendor-alph --from ../alph` refreshes it).

both use `METTLE` (default `../Mettle/bin/mettle`). set `METTLE_WIN` to a windows build of the compiler to add wine builds and tests, or `SKIP_WINE=1` to skip them.

## license

apache 2.0, see [LICENSE](LICENSE).
