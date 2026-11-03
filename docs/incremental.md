# Incremental builds

The Mettle compiler takes a whole program at once: one entry file and
everything it imports, compiled together. There is no separate compilation of
modules, so the unit mbuild reuses is one finished program, per (bin, target,
profile), plus one object per C source file.

```text
$ mbuild build
       Fresh app (linux, debug)
    Finished in 0.0s
```

## The build fingerprint

Before compiling a program, mbuild hashes everything that can change the
output:

- the compiler's identity: its file name, size and modification time (not
  its directory);
- the compiler's arguments: every flag, `-I`, and the native
  `-L`/`-l`/`--rpath`/`--link-arg` arguments, with the project root written
  as `@root`. Not the program that runs the compiler (`wine` or the compiler
  itself) and not the environment set for the command (`WINEPATH`, colour
  settings), which differ between hosts for the same build;
- the target, the profile and the bin name;
- every file in the program's import graph, standard library included, by
  content hash and by path: relative to the project root (or to the
  compiler's stdlib), and with wine's `Z:` drive dropped elsewhere;
- every file embedded with `import_str`, by path and content hash;
- every import that did not resolve, so creating that file triggers a
  rebuild;
- the native inputs: every library file copied beside the binary (the C
  libraries and the libraries found under `[link] paths`), by path and
  content hash.

The fingerprint is compared with `.mbuild/stamps/<target>-<profile>-<bin>.stamp`.
When they match and the output exists, the build prints `Fresh` and runs no
compiler. The libraries beside the binary are still refreshed if they
changed. The stamp is deleted before a compile and written only after it
succeeds, so a failed or interrupted build never looks done.

Content is hashed, not timestamps. Touching a file changes nothing; changing a
byte rebuilds:

```text
$ touch src/main.mettle && mbuild build
       Fresh app (linux, debug)
    Finished in 0.0s
$ echo '// note' >> src/main.mettle && mbuild build
   Compiling app (linux, debug)
    Finished in 0.0s
```

Under `-v`, mbuild prints how it got there, and no compiler command:

```text
$ mbuild -v build
  > dependencies: mbuild.lock unchanged, checkouts current
  > mettle for linux: ~/.mbuild/toolchains/v0.17.0/linux/bin/mettle (newest installed toolchain v0.17.0)
  > C compiler for linux: /bin/cc
  > fresh: .mbuild/cache/linux/c/vecmath/csrc/vec.c.o
       Fresh app (linux, debug)
    Finished in 0.0s
```

Things that are not in the fingerprint: the contents of system libraries
named with `-l` or found through pkg-config (only their names, through the
command), and environment variables other than those mbuild sets for the
compile. After upgrading a system library, rebuild with `--force`.

Paths are hashed relative to the project root, so moving the project does
not rebuild it, and Linux mbuild and `mbuild.exe` under wine agree: building
with one and then the other leaves everything `Fresh`, as long as both pick
the same compilers (for example through `[toolchain] mettle` or
`MBUILD_METTLE_LINUX` / `MBUILD_METTLE_WINDOWS`). Switching to another
compiler rebuilds.

## Parallel compiles

Independent programs compile at the same time: every (bin, target) pair that
is not `Fresh` starts as soon as a slot is free, up to `-j N` (`MBUILD_JOBS`,
default 8). `-j 1` compiles one at a time. Each compiler's output is printed
when it is done, in the same order as a sequential build, so diagnostics never
interleave. After a failure no new compile starts; those already running
finish and are reported.

```text
$ mbuild build -t all
   Compiling app (linux, debug)
   Compiling tool (linux, debug)
   Compiling app (windows, debug)
   Compiling tool (windows, debug)
    Finished in 1.2s
```

## Tests

`mbuild test` caches like `go test`. For each test file it hashes the
compiler's identity, the `mettle test` arguments (`-I`, `--prelude` when
`[build] prelude` is set, `[build] flags`, the profile's flags, the bin's
flags when the file is a bin's main file, and `--filter`), the target, and
the file's import graph. When the file passes, the
fingerprint is recorded in `.mbuild/stamps/test-<fingerprint>`. An unchanged
passing file is not run again:

```text
$ mbuild test
ok     src/shout.mettle (1 passed)
test result: ok. 1 passed, 0 cached, 0 failed in 0.0s
$ mbuild test
ok     src/shout.mettle (cached)
test result: ok. 0 passed, 1 cached, 0 failed in 0.0s
```

A failing file is never cached, so it runs every time until it passes. Each
target is cached separately:

```text
$ mbuild test -t all
ok     src/shout.mettle [linux] (cached)
ok     src/shout.mettle [windows] (1 passed)
test result: ok. 1 passed, 1 cached, 0 failed in 2.1s
```

A different `--filter` is a different command, so it runs.

Test files are the project's own `.mettle` files with an `@test` function.
mbuild does not look inside dot directories, `build/` directories (at any
depth), local path packages, or nested projects (a subdirectory with its own
`mbuild.toml`); run `mbuild test` inside a nested project to test it.

`mettle test` runs tests in the compiler's interpreter, without generating
code, and the interpreter cannot call C: an `extern` a test reaches (one
declared in the project, a dependency or a `[c]` source) gives an undefined
result rather than calling the library, even when `[link]` or `[c]` would
provide it. When such a test fails, mbuild says so and names the externs:

```text
FAILED e_test.mettle
note: `mettle test` runs tests in the compiler's interpreter, which cannot call C functions: the externs this file reaches (mbx_answer) give an undefined result there. Test code that needs them in a program (`mbuild run`).
```

Test code that depends on C through a program instead (a bin that checks
results and exits non-zero).

## C objects

Each C source compiles to `.mbuild/cache/<target>/c/<package>/<file>.o`, with
a depfile (`.d`) from `-MMD -MF`, a log, and a stamp. The object's fingerprint
covers:

- the C compiler's identity (path, size, modification time);
- the compile command (every flag, include directory and path);
- the source's content;
- every header the depfile lists, by path and content.

Only sources whose fingerprint changed are compiled, in parallel up to `-j N`
(`MBUILD_JOBS`, default 8). The status line counts them:

```text
   Compiling vecmath (C, 1 file)
```

Editing a header recompiles only the sources that include it. A cflags change
recompiles them all.

The package's shared library has its own stamp, over the C compiler, the link
command and the content of every object. It is relinked only when one of
those changed. Since the program's fingerprint includes the library's
content, a C change that produces identical objects leaves the program
`Fresh`:

```text
$ echo '/* x */' >> .mbuild/deps/github.com/demo/vecmath/csrc/include/vec.h
$ mbuild build
   Compiling vecmath (C, 1 file)
       Fresh app (linux, debug)
    Finished in 0.0s
```

## Dependencies

Resolving dependencies can mean running git for every module. mbuild skips
all of it when nothing changed: `.mbuild/deps.stamp` records a hash of
`mbuild.lock` and a hash of the requirements (the `[dependencies]` of the
manifest and of every path package). When both match, and every locked
module's checkout records its locked commit in `.mbuild-commit`, mbuild uses
the checkouts as they are and starts no git command.

```text
  > dependencies: mbuild.lock unchanged, checkouts current
```

Otherwise it resolves, reusing every pin in the lock that still matches
([Dependencies](dependencies.md#the-lock)), and checks out only modules whose
commit changed.

The fast path checks commits, not file contents. If you edit files inside
`.mbuild/deps`, the edits stay until the commit changes or you run
`mbuild clean --all`.

## Compiler versions

`mbuild doctor` and `mbuild toolchain` show each compiler's version. Asking
the Windows compiler means starting wine, so the answers are cached in
`$MBUILD_HOME/toolchains/versions.cache`, keyed by the compiler's path, size
and modification time.

## --force

`--force` ignores every up-to-date stamp: programs, tests, C objects and C
libraries are all built again.

```text
$ mbuild build --force
   Compiling vecmath (C, 1 file)
   Compiling app (linux, debug)
    Finished in 0.0s
```

It does not resolve dependencies again; the dependency fast path depends on
the lock and the requirements, not on stamps. To move dependencies, use
`mbuild update`.

## clean

```text
$ mbuild clean
     Removed build
     Removed .mbuild/cache
     Removed .mbuild/stamps
     Removed .mbuild/tmp
```

`mbuild clean` removes the outputs, the C cache and every stamp, so the next
build and test run compile everything. Checkouts stay, so no git is needed.

`mbuild clean --all` removes `build/` and all of `.mbuild/`, checkouts
included. The next build checks them out again from the git mirrors in
`$MBUILD_HOME/git`, which `clean` never touches.
