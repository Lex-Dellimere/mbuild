# Dependencies

mbuild fetches packages straight from git repositories. There is no registry.
A package is a git repository, a version is a tag, and the import path says
where the repository lives.

The transcripts on this page use the local stand-in repositories that
`tests/fixtures/make-fixtures.sh` builds, with `MBUILD_GIT_BASE` pointing at
them. Against GitHub the output is the same.

## Import paths

Import a file from another package by its full path: the repository path, then
the file inside the repository.

```mettle
import "github.com/demo/strutil/strutil";      // strutil.mettle at the repository root
import "github.com/demo/vecmath/vecmath";
import "github.com/someone/json/codec/read";   // codec/read.mettle
```

An import is remote when its first component contains a dot. Its module is the
first three components, `host/owner/repo`: `github.com/demo/strutil`. mbuild
clones `https://github.com/demo/strutil` and checks out the selected commit in
`.mbuild/deps/github.com/demo/strutil/`. The compiler finds the file through
the `mettle.deps` block mbuild maintains ([The manifest](manifest.md#mettledeps)).

Auto-detection assumes `host/owner/repo`. A module whose path is longer has to
be declared in `[dependencies]` yourself.

An alias imports a module under a short name:

```toml
[dependencies]
json2 = { module = "github.com/other/json", version = "v2.0.1" }
```

```mettle
import "json2/codec/read";
```

An alias is visible only to the files of the package that declares it. mbuild
writes a managed `mettle.deps` block into every checkout under `.mbuild/deps`
and into every local path package's directory, holding the host lines (which
point at your project's `.mbuild/deps`) and that package's own aliases. The
compiler reads the nearest `mettle.deps` first, so a dependency that imports
`su/strutil` gets its own `su`, and two packages can use one alias name for
different modules. Your project's own block holds only the hosts, your
aliases and your path packages. In a path package's `mettle.deps`, as in
yours, lines outside the block are kept; the block points at the project that
last resolved, so a path package shared by two projects follows whichever ran
last.

A local package is a directory:

```toml
[dependencies]
mylib = { path = "../mylib" }
```

```mettle
import "mylib/widget";
```

## Adding a dependency by importing it

Write the import and build. mbuild sees that the import does not resolve,
picks the newest release tag, writes it into `mbuild.toml`, and resolves
again:

```mettle
import "std/io";
import "github.com/demo/strutil/strutil";

fn main() -> int32 {
  println(su_shout("hello"));
  return 0;
}
```

```text
$ mbuild run
    Fetching github.com/demo/strutil
      Adding github.com/demo/strutil v1.1.0
   Resolving dependencies
   Compiling hello (linux, debug)
    Finished in 0.0s
     Running build/linux/debug/hello
hello!
```

```toml
[dependencies]
"github.com/demo/strutil" = "v1.1.0"
```

This happens in `build`, `run`, `test` and `check`. The version written is a
concrete one: the highest stable version tag (`v2.0.0-rc.1` lost to `v1.1.0`
above), else the highest pre-release, else, for a repository with no version
tags, the name of its default branch:

```text
    Fetching github.com/demo/nomanifest
      Adding github.com/demo/nomanifest main
```

With `--locked` or `--offline`, mbuild does not add anything. It names the
import and the command to run:

```text
$ mbuild build --locked
error: src/main.mettle:2: cannot find `github.com/demo/nomanifest/greet` (module github.com/demo/nomanifest is not a dependency)
error: missing dependencies (--locked stops mbuild from adding it)
  help: run `mbuild get github.com/demo/nomanifest`
```

A module that is already in the graph because another dependency requires it
resolves without being declared, since its checkout is present. `mbuild tidy`
adds such imports to `[dependencies]` at the version already selected (like
Go, a direct import of a transitive module never moves it), which keeps them
from disappearing when the dependency that pulled them in changes. Automatic
additions during a build do the same for a module already in `mbuild.lock`.

## Version specs

| Spec | Meaning |
|---|---|
| `"v1.2.3"` | Version 1.2.3 or higher, by minimal version selection. The tag `1.2.3` also matches. |
| `"v1.2"`, `"v1"` | A partial version: the lowest matching tag (`v1.2.x`, `v1.x.y`) as a minimum. `mbuild get m@v1` picks the highest matching tag instead. |
| `"v2.0.0-rc.1"` | A pre-release, matched exactly like any version. |
| `"latest"` | The highest stable version tag, else the highest pre-release, else the head of the default branch. Pinned in the lock on first use. |
| `"main"` | A branch. Pinned to its current commit in the lock. |
| `"some-tag"` | A tag that is not a version. |
| `"8ae2712"` | A commit, 7 to 40 hex digits. |

The lock pins every spec to a commit. A build never moves a pin: a branch that
gained commits, or a `latest` that has a newer tag, stays where the lock says
until you run `mbuild get` or `mbuild update`. A tag that was moved in the
repository keeps its locked commit too, with a warning:

```text
warning: tag v1.0.0 of github.com/demo/strutil moved upstream (3e687bc -> 9a1f0c2); keeping 3e687bc; run `mbuild update github.com/demo/strutil` to take 9a1f0c2
```

`mbuild update MODULE` then takes the new commit and says so:

```text
    Updating github.com/demo/strutil v1.0.0 (tag moved upstream: 3e687bc -> 9a1f0c2)
```

When the error is a version that does not exist, mbuild lists what does:

```text
$ mbuild get github.com/demo/strutil@v9
    Fetching github.com/demo/strutil
error: github.com/demo/strutil has no version v9 (required by the command line)
  help: available versions: v1.0.0, v1.1.0, v2.0.0-rc.1; branches: main
```

## Minimal version selection

Every package can have an `mbuild.toml` with its own `[dependencies]`. mbuild
walks the requirement graph from your project: for each (module, version) it
visits, it reads that version's `mbuild.toml` straight from the git mirror and
queues its requirements. Then it selects, for each module, the highest version
anyone asked for. Nothing newer than that is chosen, even when it exists.

The fixtures show it. `vecmath v0.2.0` requires `strutil v1.1.0`. The project
asks for `strutil v1.0.0`:

```toml
[dependencies]
"github.com/demo/vecmath" = "v0.2.0"
"github.com/demo/strutil" = "v1.0.0"
```

```text
$ mbuild deps --tree
   Resolving dependencies
      Adding github.com/demo/strutil v1.1.0
      Adding github.com/demo/vecmath v0.2.0
conf
|-- github.com/demo/vecmath v0.2.0 [native: C; c libs: m]
|   `-- github.com/demo/strutil v1.1.0
`-- github.com/demo/strutil v1.1.0 (requires v1.0.0)
```

`v1.1.0` is selected: it is the highest version required. `v2.0.0-rc.1` exists
but nobody asked for it.

Versions are compared as semantic versions. A branch, a non-version tag or a
commit cannot be compared, so a non-version requirement your own manifest
states wins outright, and mbuild warns when the graph disagrees:

```text
warning: conflicting requirements for github.com/demo/strutil:
    mbuild.toml requires main
    github.com/demo/vecmath v0.2.0 requires v1.1.0
  using main
```

When only dependencies state non-version requirements, the version
requirements still win if there are any; otherwise the first requirement seen
is kept.

## The lock

`mbuild.lock` records the selected version and commit of every module
([format](manifest.md#mbuildlock)). Commit it. With the lock in place, a clone
on another machine checks out exactly the same commits.

Resolution reuses the lock wherever a pin still matches its requirement: the
same version for a version spec, the same branch or commit for a named spec,
any locked entry for `latest`. Change a requirement in `mbuild.toml` and only
that module gets a new pin. Whenever the lock changes, mbuild says how:

```text
      Adding github.com/demo/nomanifest main
    Updating github.com/demo/strutil v1.1.0 -> v1.0.0
    Updating github.com/demo/nomanifest main (65769e6 -> 83c3c8f)
```

Checkouts that are no longer selected are removed from `.mbuild/deps`.

## Commands

### mbuild get MODULE[@VERSION]...

Adds a requirement or changes one, then resolves. `VERSION` is any spec from
the table above; it defaults to `latest`. mbuild writes the concrete version it
found, not the word `latest`:

```text
$ mbuild get github.com/demo/vecmath
    Fetching github.com/demo/vecmath
      Adding github.com/demo/vecmath v0.2.0
   Resolving dependencies
```

```text
$ mbuild get github.com/demo/strutil@v1.0.0
    Fetching github.com/demo/strutil
    Updating github.com/demo/strutil v1.1.0 -> v1.0.0
   Resolving dependencies
```

`MODULE` may also be an alias key from `[dependencies]` (`mbuild get
json2@v2.1.0`). A path dependency cannot be changed this way; edit its `path`.

A repository URL works as well and is turned into its module path:
`https://github.com/a/b`, `http://...`, `ssh://git@github.com/a/b`,
`git@github.com:a/b`, each with or without a trailing `.git` or `/`, all mean
`github.com/a/b` (`mbuild get git@github.com:a/b.git@v1.2.0`). The URL is not
recorded; to fetch from it, set `url` (see [Where modules come
from](#where-modules-come-from)).

### mbuild remove MODULE...

Removes the requirement (by module path or key) from `mbuild.toml`, then
resolves. A module that is still required by another dependency stays in the
lock, at the version that dependency asks for:

```text
$ mbuild remove github.com/demo/vecmath
    Removing github.com/demo/vecmath from mbuild.toml
   Resolving dependencies
    Updating github.com/demo/strutil v1.1.0 -> v1.0.0
```

Here `vecmath` had raised `strutil` to `v1.1.0`. Without it, the project's own
`v1.0.0` is the highest requirement left.

### mbuild update [MODULE... | --all]

Brings requirements forward to what the remotes have now. For each
requirement in `mbuild.toml` (or only the named ones), mbuild refreshes the
mirror and then:

- a full version such as `v1.0.0` moves to the newest tag with the same major
  version (pre-releases only when the current version is one), and
  `mbuild.toml` is edited;
- `latest` and branches are re-resolved, so their pins move to the current
  tag or commit;
- partial versions (`v1`, `v1.2`) and commits stay as written.

Then the whole graph is resolved again with the old pins ignored.

```text
$ mbuild update
    Fetching github.com/demo/strutil
    Updating github.com/demo/strutil v1.0.0 -> v1.1.0
   Resolving dependencies
$ mbuild update
    Fetching github.com/demo/strutil
   Resolving dependencies
     Checked dependencies are up to date
```

A new major version is never picked by `update`. Ask for it with
`mbuild get MODULE@v2.0.0`.

Modules that only dependencies require stay at the version minimal version
selection gives them. `mbuild update --all` raises those too: every selected
module whose version is a tag moves to the newest tag with the same major
version. Selection only ever picks a version somebody requires, so mbuild
records each raised module as a requirement in your `mbuild.toml` (repeating
until nothing more moves, since a raised module may require others):

```text
$ mbuild update --all
    Fetching github.com/demo/strutil
    Updating github.com/demo/strutil v1.0.0 -> v1.1.0 (now required in mbuild.toml)
   Resolving dependencies
```

`mbuild tidy` removes such a requirement again if nothing in your own code
imports the module.

### mbuild tidy

Scans every bin and every file with `@test` functions, for both targets,
looking at the imports of your own package's files. It adds remote modules
they import but `mbuild.toml` does not require (at the version already
selected when the module is in the graph, else the latest), and removes
requirements they do not import: modules, aliases whose key is not imported,
and path dependencies:

```text
$ mbuild tidy
    Removing github.com/demo/vecmath (not imported)
   Resolving dependencies
```

### mbuild deps [--tree]

Lists the selected modules. Branches and commits show their short commit, and
`[native: ...]` marks packages with C code or `[link]` libraries, naming the
libraries the C code links (`c libs`, from `[c]`/`[c.linux]`/`[c.windows]`)
and those the package's externs bind (`link libs` and `pkgconfig`, from
`[link]` and its OS sections):

```text
$ mbuild deps
github.com/demo/nomanifest main (65769e6)
github.com/demo/strutil v1.0.0
github.com/demo/vecmath v0.1.0 [native: C; c libs: m]
mylib (path ../mylib) [native: link libs: z]
```

`--tree` shows who requires what. `(requires X)` marks a requirement that was
raised by selection, `(not selected)` one that was not used, and `(*)` a
subtree already printed above:

```text
$ mbuild deps --tree
app 0.1.0
|-- github.com/demo/vecmath v0.1.0 [native: C; c libs: m]
|   `-- github.com/demo/strutil v1.0.0
`-- github.com/demo/nomanifest main (65769e6)
```

### mbuild fetch

Resolves from the lock, downloads every module it names into the mirror
cache, and checks them out:

```text
$ mbuild fetch
   Resolving dependencies
     Fetched 1 module(s); builds can now run with --offline
```

With `--force` (on `fetch` or on any build), every selected checkout is
checked out and cleaned again (`git checkout --force` and `git clean -ffdx`),
which restores files edited or deleted inside `.mbuild/deps`, and the
checkouts' `mettle.deps` blocks are rewritten.

## Offline and locked builds

`--offline` never touches the network. Dependencies resolve from the mirrors
already in `$MBUILD_HOME/git`, and toolchains are never downloaded. A module
with no mirror is an error that points at `mbuild fetch`:

```text
$ mbuild build --offline
   Resolving dependencies
error: github.com/demo/strutil (required by mbuild.toml) is not downloaded and --offline forbids fetching it
  help: run `mbuild fetch` once while online, or drop --offline
```

A commit missing from an existing mirror is an error too.

`--locked` refuses every change to `mbuild.toml` and `mbuild.lock`: no
automatic additions, no `get`, `remove`, `update`, `tidy` or
`toolchain use`, and a build fails when the lock is missing or out of date:

```text
$ mbuild build --locked
   Resolving dependencies
error: mbuild.lock is out of date and --locked forbids changing it
  help: run the command without --locked (for example `mbuild fetch`) and commit the new mbuild.lock
```

For CI, `mbuild fetch` once and then build with `--locked --offline`.

## Where modules come from

For each module, the URL is the first of:

1. the requirement's `url` field;
2. `$MBUILD_GIT_BASE/<module>`, when `MBUILD_GIT_BASE` is set;
3. `https://<module>`.

`url` takes anything git accepts: `https://...`, `ssh://...`,
`git@host:owner/repo.git`, or a local path. When the project and a dependency
both give a `url` for the same module, the project's wins.

`MBUILD_GIT_BASE` is a directory or URL under which repositories sit at their
module paths. Point it at a company mirror
(`https://git.example.com/mirror`, so `github.com/a/b` is fetched from
`https://git.example.com/mirror/github.com/a/b`) or at a local directory of
repositories, which is how mbuild's own tests run.

Private repositories: mbuild runs git with `GIT_TERMINAL_PROMPT=0` and,
unless you set `GIT_SSH_COMMAND` yourself, `GIT_SSH_COMMAND="ssh -o
BatchMode=yes"`, so git fails instead of asking for a password or a key
passphrase. Use a URL your credentials already cover, such as an SSH URL with
a key loaded in `ssh-agent`, or an HTTPS URL with a git credential helper:

```toml
[dependencies]
"github.com/acme/internal" = { version = "v1.4.0", url = "git@github.com:acme/internal.git" }
```

Rather than a `url` in every manifest, you can let git rewrite the default
HTTPS URLs on your machine, which keeps the manifests portable:

```sh
git config --global url."git@github.com:acme/".insteadOf "https://github.com/acme/"
```

mbuild still passes `https://github.com/acme/internal` (and keeps the default
mirror name); git fetches it over SSH. An HTTPS token works the same way:
`git config --global url."https://TOKEN@github.com/acme/".insteadOf
"https://github.com/acme/"`, or a credential helper
(`git config --global credential.helper store`).

A failed download names the URL and what to change:

```text
   Resolving dependencies
    Fetching github.com/demo/nope
error: cannot download github.com/demo/nope (required by mbuild.toml) from /home/you/gitbase/github.com/demo/nope
  git: fatal: repository '/home/you/gitbase/github.com/demo/nope' does not exist
  help: MBUILD_GIT_BASE=/home/you/gitbase is set, so mbuild looked for the repository at /home/you/gitbase/github.com/demo/nope; unset it, or add the repository there
```

`MBUILD_GIT` names the git program when it is not on PATH.

## The git mirror cache

Each module is cloned once per machine, as a bare mirror in
`$MBUILD_HOME/git/<module>.git` (`git clone --mirror`). Every project on the
machine shares it. A module fetched from any other URL (a `url` field, or
`MBUILD_GIT_BASE`) gets its own mirror, `$MBUILD_HOME/git/<module>@<hash of
the URL>.git`, so two projects that fetch one module from different places do
not overwrite each other's mirror.

Cloning and fetching hold a lock directory `<mirror>.lock`, so mbuild runs in
parallel (two projects, or a build and an editor integration) take turns on a
mirror. A run that finds the lock waits up to 60 seconds
(`Waiting for another mbuild using ...`). On Linux a lock older than ten
minutes, left by a run that was killed, is removed with a warning; elsewhere
the wait times out with a message naming the lock directory to delete. A new
mirror is cloned to `<mirror>.new` and renamed into place, so no run ever
sees a half-made one. A project's checkout in `.mbuild/deps/<module>` is a
`git clone --shared` of the mirror, so it borrows the mirror's objects instead
of copying them.

mbuild refreshes a mirror (`git fetch --prune --tags --force`) only when it
needs something the mirror lacks: a tag or commit it cannot find, a `latest`
or branch requirement that is not pinned yet, or `mbuild get` and
`mbuild update`. Each mirror is fetched at most once per command. When nothing
changed, a build runs no git command at all
([Incremental builds](incremental.md#dependencies)).

Deleting `$MBUILD_HOME/git` is safe. The next build that needs a mirror clones
it again, unless `--offline` is given.

## Writing a package others can use

A package is a git repository whose files other projects import. To publish
one:

1. Give it an `mbuild.toml` with its `name`, its `module` path and its own
   `[dependencies]`:

   ```toml
   [package]
   name = "vecmath"
   module = "github.com/demo/vecmath"
   version = "0.1.0"

   [dependencies]
   "github.com/demo/strutil" = "v1.0.0"

   [c]
   sources = ["csrc"]
   include = ["csrc/include"]

   [c.linux]
   libs = ["m"]
   ```

2. Tag releases as semantic versions: `git tag v0.1.0`. mbuild reads tags,
   not the `version` key, when it selects versions. A repository with no
   tags still works; users then get a branch pin.

3. Inside the package, import your own files relatively (`import "util";`).
   Relative imports resolve the same way whether the package is the project
   being built or a checkout under someone else's `.mbuild/deps`. Import other
   packages by their full module path.

4. State the lowest version of each dependency that works, not the newest.
   Minimal version selection raises it when the user's graph needs more.

5. Leave out `path` dependencies. They are ignored when your package is
   fetched.

6. Put C code under `[c]` and libraries under `[link]`
   ([Native code](native.md)). They are compiled and linked into every program
   that imports the package, for both targets.

Users then write `import "github.com/demo/vecmath/vecmath";` and build. A
package does not need an `mbuild.toml` at all if it has no dependencies and no
native code; the fixture `github.com/demo/nomanifest` has none.
