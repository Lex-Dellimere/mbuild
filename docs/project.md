# The project file: mbuild.mettle

`mbuild.mettle` sits at the project root (mbuild walks up from the working
directory to find it) and is Mettle code. `fn project()` describes the
package, every `fn cmd_NAME` is a command, `fn hook_pre_build` and
`fn hook_post_build` run around builds.

```mettle
import "mbuild/api";

fn project() {
  mb_package("viewer", "0.3.0");
  mb_meta("description", "image viewer");
  mb_dep("strutil", "v1.1.0");

  mb_profile("release");
  mb_set("crash-report", "false");
  mb_on("windows");
  mb_set("subsystem", "windows");
  mb_on("");
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

- `fn project()` is required. No `fn main`.
- Import the API plainly: `import "mbuild/api";`, never `as`.
- If the file exports anything, `project`, every `cmd_*` and every `hook_*`
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
| `mb_targets(csv)` | What `build`, `check` and `doctor` build without `-t`: `"linux"`, `"windows"`. Default: the host. |
| `mb_flags(csv)` | Raw compiler flags for every compile. Prefer typed settings (below). |
| `mb_prelude(on)` | Pass `--prelude`, so `std/prelude` is imported everywhere. |
| `mb_agents(on)` | Keep the dependencies block in `AGENT.rules` ([packages](packages.md#agentrules)). Default `true`. |
| `mb_publish_include(csv)` | The files `mbuild publish` packs ([dependencies](dependencies.md#publishing)). |
| `mb_import_root(dir)` | Imports of `name/...` start in `dir` instead of the package root ([dependencies](dependencies.md#import-roots)). |
| `mb_raw(section, key, toml)` | Escape hatch: a raw key in the generated manifest. |

### Dependencies

| Call | Meaning |
|---|---|
| `mb_dep(name, version)` | A package from the registries, `"v1.2.0"` or higher. |
| `mb_dep_from(registry, name, version)` | The same, from one named registry. |
| `mb_dep_path(name, path)` | A package in a local directory. |
| `mb_dep_bin(dep, bin)` | Also build bin `bin` of dependency `dep` (below). |
| `mb_registry(name, url)` | A registry, searched in call order before `default`. |
| `mb_replace_version(name, version)` | One version of `name` for the whole build. |
| `mb_replace_path(name, path)` | Use a local directory instead of `name` everywhere in the build. |

`get`, `remove`, `update`, `tidy` and auto-add edit the `mb_dep*` lines and
leave the rest of the file alone. They can only edit a call on its own line
inside `fn project()` with string literal arguments; anything else gets an
error that shows the line to write. See [dependencies](dependencies.md).

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
and C code, into the same directory. `mbuild run` doesn't start it; your
program can.

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

### Native code, components, rules

`mb_c_sources`, `mb_c_include`, `mb_c_flags`, `mb_c_libs`, `mb_link_libs`,
`mb_link_paths`, `mb_pkgconfig` are in [native code](native.md).
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
apply to that OS only, until `mb_on("")`.

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
error: no command 'instal'
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
| `mb_out(bin, target, profile)` | absolute path of a built bin |
| `mb_mbuild(args)` | runs this mbuild with `args` (split on spaces) and returns its exit code; nests at most 8 deep |

### Processes and files

| Call | Does |
|---|---|
| `mb_cmd(program)` | a command to run, found on PATH |
| `mb_cmd_arg(c, s)`, `mb_cmd_cwd(c, dir)`, `mb_cmd_env(c, "NAME=value")` | add an argument, set its directory, set a variable for it only |
| `mb_cmd_run(c)` | runs it with your terminal, returns the exit code (127: could not start) |
| `mb_cmd_output(c)` | runs it, returns stdout without one trailing newline; the exit code is then `mb_cmd_status(c)` |
| `mb_sh(line)` | runs a line through `sh -c` (Linux) or `cmd /c` (Windows) |
| `mb_env(name)`, `mb_home()` | an environment variable, the home directory |
| `mb_exists(p)`, `mb_is_dir(p)` | |
| `mb_read(p)` | the file's content, `""` when unreadable |
| `mb_write(p, data)` | writes it, creating parent directories |
| `mb_write_if_changed(p, data)` | the same, only when the content differs; true when it wrote |
| `mb_copy(src, dst)` | copies a file, keeping the executable bit |
| `mb_mkdirs(p)`, `mb_remove(p)` | `mb_remove` takes a file or a whole directory |
| `mb_say(s)`, `mb_warn(s)`, `mb_fail(s)` | prints to stdout; `warning: s` on stderr; `error: s` on stderr and exit 1 |

Relative paths are relative to the project root.

## Hooks

`fn hook_pre_build() -> int32` runs once per target and profile of every
command that compiles (`build`, `run`, `check`, `test`, `live`), after
dependencies are ready and before mbuild decides what is Fresh, so files it
writes are part of the build. It runs every time; write with
`mb_write_if_changed` and an unchanged build stays Fresh.

`fn hook_post_build() -> int32` runs once per target and profile after the
bins are linked (`build`, `run`, `live`), also when everything was Fresh.

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
unset. `mbuild doctor` and `mbuild toolchain` show where each came from.

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
