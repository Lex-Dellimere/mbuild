# The manifest: mbuild.toml

`mbuild.toml` sits at the root of a project. mbuild finds it by walking up
from the working directory. Only `[package] name` is required.

```toml
[package]
name = "app"
version = "0.1.0"
module = "github.com/you/app"

[toolchain]
mettle = "v0.17.0"

[build]
targets = ["linux", "windows"]
flags = ["--safe"]
prelude = false

[profile.release]
flags = ["--release"]

[profile.fast]
flags = ["--release", "--check-overflow"]

[bin.app]
main = "src/main.mettle"

[bin.tool]
main = "tools/tool.mettle"
flags = ["--explain"]

[dependencies]
"github.com/someone/json" = "v1.2.0"
"github.com/someone/edge" = "main"
json2 = { module = "github.com/other/json", version = "v2.0.1" }
mylib = { path = "../mylib" }
"gitlab.com/team/proto" = { version = "v1.0.0", url = "https://mirror.example.com/proto.git" }

[c]
sources = ["csrc"]
include = ["csrc/include"]
cflags = ["-O2"]

[c.linux]
libs = ["m"]

[link]
libs = ["raylib"]
paths = ["vendor/lib"]

[link.linux]
pkgconfig = ["zlib"]
```

## Values and checking

A value is a string, an array of strings, or a boolean. Where a key takes an
array, a single string counts as an array of one: `libs = "m"` is
`libs = ["m"]`.

A wrong type, a missing `name`, or a malformed dependency stops every command
with the file and line. An unknown section or key is a warning, with a
suggestion when a known name is close:

```text
warning: mbuild.toml:4: unknown section [biuld] (did you mean [build]?)
warning: mbuild.toml:8: unknown key 'flagz' in [build] (did you mean 'flags'?)
   Compiling typo (linux, debug)
    Finished in 0.0s
```

```text
error: mbuild.toml:5: dependency 'json' needs a module or a path, e.g. json = { module = "host/owner/repo", version = "v1.0.0" }
  help: see docs/manifest.md for the manifest format
```

The file is named relative to the working directory (`../mbuild.toml` from a
subdirectory of the project).

A key outside any section is ignored with a warning.

## [package]

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | required | The package name. Letters, digits, `_`, `-` and `.` only. It names the default bin and the package's C library (`mb_<name>`). |
| `version` | string | none | The package's version. A value that is not a semantic version gets a warning. `mbuild deps --tree` shows it. |
| `module` | string | none | The import path other projects use for this package, such as `github.com/you/app`. It must start with a host (a first component holding a dot). mbuild never fetches this module as a dependency of the package itself. |

`mbuild init github.com/you/app` writes `name = "app"` and
`module = "github.com/you/app"`.

## [toolchain]

| Key | Type | Default | Meaning |
|---|---|---|---|
| `mettle` | string | none | Pin a Mettle release, such as `"v0.17.0"` (`"0.17.0"` means the same). It must be a release version, not `latest`. |

A pinned release is installed under `$MBUILD_HOME/toolchains/<version>/` and
downloaded the first time a build needs it, unless `--offline` is given.
`mbuild toolchain use VERSION` installs a release and writes this key. Without
a pin, mbuild looks for a compiler in other places; see
[Platforms](platforms.md#which-compiler-builds-a-target).

## [build]

| Key | Type | Default | Meaning |
|---|---|---|---|
| `targets` | array | the host | What `mbuild build`, `check` and `doctor` build without `-t`. Each is `"linux"` or `"windows"`. |
| `flags` | array | `[]` | Compiler flags for every compile of every bin. |
| `prelude` | bool | `false` | Pass `--prelude`, so `std/prelude` is imported everywhere (`mbuild test` passes it too). |

## [profile.NAME]

| Key | Type | Default | Meaning |
|---|---|---|---|
| `flags` | array | see below | Compiler flags for builds in this profile. |
| `cflags` | array | `[]` | C flags appended to every package's C compiles (this project's and its dependencies') in this profile. Only the project's own manifest counts. |

Two profiles always exist. `debug` is the default and passes no flags.
`release` (`-r`, `--release`) passes `["--release"]`. Writing `flags` in
`[profile.release]` replaces that default, so keep `"--release"` in the list
if you want it.

No profile adds C flags by default, not even `release`. To optimise C code in
release builds:

```toml
[profile.release]
flags = ["--release"]
cflags = ["-O2"]
```

A profile with `cflags` keeps its C objects and libraries apart
(`.mbuild/cache/<target>/c-<profile>/` and `lib-<profile>/`), so switching
between profiles does not recompile C code twice. A dependency's own
`[profile.*]` sections are ignored. See
[Native code](native.md#c-flags-per-profile).

Any other `[profile.NAME]` section adds a profile, selected with `-p NAME`.
`-r` wins over `-p`. Outputs go to `build/<target>/<profile>/`. Naming a
profile that does not exist fails:

```text
error: unknown profile `fast`
  help: the profiles are: debug, release (add [profile.fast] to mbuild.toml)
```

## [bin.NAME]

| Key | Type | Default | Meaning |
|---|---|---|---|
| `main` | string | required | The entry file, relative to the project root. |
| `flags` | array | `[]` | Compiler flags for this bin only. |

`NAME` follows the same rules as the package name. The output is
`build/<target>/<profile>/NAME`, with `.exe` for Windows.

A compile passes the flags in this order: `--prelude` (when set),
`[build] flags`, the profile's flags, the bin's flags, then the native
arguments mbuild adds for C libraries ([Native code](native.md)). mbuild also
passes `-I .mbuild/deps`. `mbuild test` passes the same flags (the bin's only
for a file that is a bin's main file), without the native arguments.

### Bin auto-detection

With no `[bin.*]` section, mbuild looks for programs itself:

1. `main.mettle`, else `src/main.mettle`, as a bin named after the package;
2. plus every `cmd/<name>/main.mettle`, as a bin named `<name>`;
3. if neither found anything, every top-level `*.mettle` file that defines
   `fn main`, as a bin named after the file.

Once any `[bin.*]` section exists, only the sections count.

A package with a manifest and no bins is a library. `mbuild check`
type-checks each of its top-level and `src/` `.mettle` files (except
`*_test.mettle` and `test_*.mettle`) on its own; `mbuild build` prints
`library: nothing to link` and does the same; `mbuild run` fails, since there
is nothing to run; `mbuild test` works as usual. Without a manifest and
without a file defining `fn main`, mbuild suggests `mbuild init`.

`mbuild run` with several bins runs the one named after the package, or asks
you to name one:

```bash
mbuild run tool -- --input data.txt
```

## [dependencies]

Each entry is one requirement. The key is either a module path
(`host/owner/repo`) or a short name of your choosing.

| Form | Meaning |
|---|---|
| `"github.com/a/b" = "v1.2.0"` | Module `github.com/a/b`, version `v1.2.0` or higher (minimal version selection). |
| `"github.com/a/b" = "latest"` | The newest release tag, pinned in the lock on first use. |
| `"github.com/a/b" = "main"` | A branch, a tag that is not a version, or a commit (7 to 40 hex digits). |
| `"github.com/a/b" = { version = "v1.2.0", url = "https://host/b.git" }` | Fetch from this URL instead of `https://github.com/a/b`. |
| `alias = { module = "github.com/a/b", version = "v2.0.1" }` | Import the module as `alias/...` instead of `github.com/a/b/...`. |
| `mylib = { path = "../mylib" }` | A package in a local directory, imported as `mylib/...`. |

The fields of an inline table are `module`, `version`, `path` and `url`, all
strings. The same entry can be written as a table:

```toml
[dependencies."github.com/a/b"]
version = "v1.2.0"
url = "https://mirror.example.com/b.git"

[dependencies.json2]
module = "github.com/other/json"
version = "v2.0.1"
```

The rules mbuild enforces:

- A key that is a module path cannot name a different `module`.
- A short key needs a `module` or a `path`.
- A `path` dependency takes neither `version` nor `url`.
- A `version` that is present cannot be empty. When it is absent, it is
  `latest`.
- A module may be required once.
- Declaring the same key inline and as a table is an error.

A path dependency's key must be a plain name such as `mylib`, without a dot
in it. The compiler matches `mettle.deps` names against the first component
of an import only, so a key like `github.com/me/mylib` cannot be published;
mbuild warns and suggests a plain key.

Path dependencies apply only to the project and to other path packages. When
a fetched package lists a path dependency, mbuild ignores it (`-v` says so).
A path package's own `[dependencies]` join the graph, and its `[c]` and
`[link]` sections are built and linked like any other package's.

Versions, selection, the lock, and the commands that edit this section are
covered in [Dependencies](dependencies.md).

## [c], [c.linux], [c.windows]

C code compiled into this package's shared library: `libmb_<name>.so` on
Linux, `mb_<name>.dll` on Windows.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `sources` | array | `[]` | Files; directories (every `.c` file below them, recursively); or `dir/*.c` (the `.c` files directly in `dir`). |
| `include` | array | `[]` | Header directories, passed as `-I`. |
| `cflags` | array | `[]` | Extra flags for every C compile. |
| `libs` | array | `[]` | Libraries the C code itself links against, passed as `-lNAME` when the shared library is linked. |

Paths are relative to the package's directory. `[c.linux]` and `[c.windows]`
take the same keys; their values are appended to `[c]` for that target.

## [link], [link.linux], [link.windows]

Libraries that the package's `extern` declarations bind directly.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `libs` | array | `[]` | Library names. Linux: `-lNAME` (`libNAME.so`; `:file` names a file exactly). Windows: `NAME.dll`. |
| `paths` | array | `[]` | Directories, relative to the package, searched for those libraries. A library found here is copied beside the binary. These directories are also passed as `-L` when the package's own C library is linked. |
| `pkgconfig` | array | `[]` | Linux only: package names expanded with `pkg-config --libs`. For the Windows target a `pkgconfig` entry is skipped with a warning. |

`[link.linux]` and `[link.windows]` are appended to `[link]` for that target.
See [Native code](native.md) for what happens on each OS.

## mbuild.lock

mbuild writes `mbuild.lock` beside the manifest. Commit it.

```text
# mbuild.lock: generated by mbuild. Commit it.
# requirements 406d2304603f7a208bd60036887053f6
# module version commit
github.com/demo/nomanifest main 65769e6b764999b84b3760d282c5ddedd13bb5db
github.com/demo/strutil v1.0.0 7675a7d9fd4b832c59d6ffdb506dce3c3e8edf13
github.com/demo/vecmath v0.1.0 8ae2712e31b97c59cbea6318cf971852bcc61752
```

One line per selected module, sorted: the module, the version it resolved to
(a tag, a branch, or a commit as written), and the full commit. The
`requirements` line is a hash over the `[dependencies]` of the manifest and of
every path package; it tells mbuild whether the requirements changed since the
lock was written. Path packages do not appear in the lock.

A project with no remote dependencies gets no lock file.

## mettle.deps

mbuild also writes a `mettle.deps` file at the project root:

```text
# >>> mbuild: generated, edits inside this block are overwritten
github.com=./.mbuild/deps/github.com
json2=./.mbuild/deps/github.com/other/json
mylib=../mylib
# <<< mbuild
```

`mettle.deps` is the compiler's own package map, not an mbuild invention: when
the compiler resolves `import "github.com/a/b/file"`, it walks up from the
importing file, finds this file, matches the first path component
(`github.com`), and looks in `./.mbuild/deps/github.com/a/b/file.mettle`. See
[Path resolution](https://github.com/suidvandiewereld/Mettle/blob/main/docs/modules.md#path-resolution)
in Mettle's docs.

That is why the block exists. Dependencies are visible to everything that runs
the compiler in this directory, not only to mbuild:

- plain `mettle --build src/main.mettle` and `mettle test`;
- editors and language servers that run the compiler;
- `mettle trace` and `mettle why`, which ignore `-I` and every other flag.

The root block holds one line per host of a fetched module, plus your own
aliases and your path packages. Every dependency checkout under
`.mbuild/deps` and every path package directory gets its own managed block,
with host lines pointing at your project's `.mbuild/deps/<host>` and that
package's own aliases. The compiler reads the nearest `mettle.deps` first, so
aliases are scoped per package: a dependency's alias is not visible to you,
and two packages can use one alias name for different modules (see
[Dependencies](dependencies.md)). Lines outside the markers are yours and are
kept. mbuild rewrites a file only when its content changes, and deletes it
when the block would be empty and nothing else is in the file. Builds also
pass `-I .mbuild/deps`.

Whether to commit `mettle.deps` is up to you. mbuild regenerates it on every
build; committing it lets a fresh clone compile with plain `mettle` after one
`mbuild fetch`.

## The .mbuild directory

`.mbuild/` holds state and is never committed (`mbuild init` adds it to
`.gitignore`, together with `/build/`):

| Path | Holds |
|---|---|
| `.mbuild/deps/<module>/` | Checkouts of the selected modules, each with a `.mbuild-commit` marker. |
| `.mbuild/deps.stamp` | What the last dependency resolution saw (lock hash and requirements hash). |
| `.mbuild/cache/<target>/c/` | C objects, depfiles, logs and stamps. |
| `.mbuild/cache/<target>/lib/` | The packages' C shared libraries. |
| `.mbuild/stamps/` | Build and test fingerprints. |
| `.mbuild/tmp/` | Scratch files. |

`mbuild clean` removes `build/`, `.mbuild/cache`, `.mbuild/stamps` and
`.mbuild/tmp`. `mbuild clean --all` removes `.mbuild` entirely, checkouts
included.
