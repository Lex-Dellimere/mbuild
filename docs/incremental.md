# Incremental builds

The Mettle compiler takes a whole program at once: one entry file and
everything it imports. There's no separate compilation of modules, so what
mbuild reuses is a finished program, per bin, target and profile, plus one
object per C source file.

```text
$ mbuild build
       Fresh hello (linux, debug)
    Finished in 0.0s
```

## The build fingerprint

Before compiling a program, mbuild hashes everything that can change it:

- the compiler: its file name, size and modification time;
- the compiler's arguments, with the project root written as `@root`, but
  not the program that runs the compiler (`wine`) or the environment set for
  it (`WINEPATH`), which differ between hosts for the same build;
- the target, the profile and the bin;
- every file in the program's import graph, standard library and generated
  component selectors included, by path and content hash;
- every file embedded with `import_str`;
- every import that didn't resolve, so creating that file triggers a
  rebuild;
- every library copied beside the binary, by content.

When it matches the stamp in `.mbuild/stamps/` and the output exists, the
build prints `Fresh` and runs no compiler. The stamp is written only after a
compile succeeds, so a failed or interrupted build never looks done.

Content is hashed, not timestamps. Touching a file changes nothing; changing
a byte rebuilds:

```text
$ touch src/main.mettle && mbuild build
       Fresh hello (linux, debug)
    Finished in 0.0s
$ echo '// note' >> src/main.mettle && mbuild build
   Compiling hello (linux, debug)
    Finished in 0.0s
```

Under `-v`, mbuild says how it got there:

```text
$ mbuild -v build
  > mettle for linux: /home/you/Mettle/bin/mettle ($METTLE)
  > dependencies: mbuild.lock unchanged, packages in place
  > mettle for linux: /home/you/Mettle/bin/mettle ($METTLE)
  > C compiler for linux: /bin/cc
  > fresh: .mbuild/cache/linux/c/vecmath/csrc/vec.c.o
       Fresh vm (linux, debug)
    Finished in 0.0s
```

Not in the fingerprint: the contents of system libraries named with
`mb_link_libs` or found through pkg-config, and environment variables other
than the ones mbuild sets. After upgrading a system library, build with
`--force`.

Paths are hashed relative to the project root, so moving the project doesn't
rebuild it. Switching to another compiler does, including Linux mbuild and
`mbuild.exe` under wine, which see the compilers under different paths.

Switching a component impl (`mbuild use`, `--use`, a profile's `mb_use`)
changes the generated selector, so exactly the affected bins rebuild.

## mbuild.mettle

Your `mbuild.mettle` is compiled into a small program once and cached by the
content of the file, `mbuild.local.mettle`, everything they import, mbuild's
version and the compiler. An unchanged project file costs a few file hashes.

## Parallel compiles

Every (bin, target) pair that isn't Fresh starts as soon as a slot is free,
up to `-j N` (`MBUILD_JOBS`, default 8). Each compiler's output is printed
when it's done, in the order of a sequential build, so diagnostics never
interleave. After a failure no new compile starts.

## Tests

`mbuild test` caches like `go test`. For each test file it hashes the
compiler, the `mettle test` arguments (including `--filter`), the target and
the file's import graph. A passing file is recorded and not run again until
something changes:

```text
$ mbuild test
ok     src/shout.mettle (1 passed)
test result: ok. 1 passed, 0 cached, 0 failed in 0.0s
$ mbuild test
ok     src/shout.mettle (cached)
test result: ok. 0 passed, 1 cached, 0 failed in 0.0s
```

A failing file is never cached. Each target is cached separately.

Test files are your project's `.mettle` files with an `@test` function.
mbuild skips dot directories, `build/` directories, path packages and nested
projects (a subdirectory with its own `mbuild.mettle`); run `mbuild test`
inside a nested project to test it.

`mettle test` runs tests in the compiler's interpreter, which can't call C.
An `extern` a test reaches gives an undefined result, and when such a test
fails mbuild says so:

```text
FAILED src/e_test.mettle
note: `mettle test` runs tests in the compiler's interpreter, which cannot call C functions: the externs this file reaches (say_c) give an undefined result there. Test code that needs them in a program (`mbuild run`).
```

## C objects

Each C source compiles to `.mbuild/cache/<target>/c/<package>/<file>.o`. Its
fingerprint covers the C compiler, the compile command, the source and every
header the depfile lists. Only changed sources compile:

```text
   Compiling vecmath (C, 1 file)
```

Editing a header recompiles only the sources that include it; a cflags change
recompiles them all. The package's shared library is relinked only when an
object or the link command changed, and since the program's fingerprint
covers the library's content, a C change that produces the same objects
leaves the program Fresh:

```text
$ echo '/* x */' >> .mbuild/deps/vecmath/csrc/include/vec.h
$ mbuild build
   Compiling vecmath (C, 1 file)
       Fresh vm (linux, debug)
    Finished in 0.0s
```

## Dependencies

When `mbuild.lock` and the requirements are unchanged and every package in
`.mbuild/deps/` is the locked version, mbuild uses them as they are and
touches no registry:

```text
  > dependencies: mbuild.lock unchanged, packages in place
```

Otherwise it resolves, reusing every pin in the lock that still matches, and
extracts only packages whose version changed. Archives come from the
download cache in `$MBUILD_HOME` and are downloaded only once.

The fast path checks versions, not file contents: edits inside
`.mbuild/deps/` stay until the version changes or you run
`mbuild clean --all`. To work on a dependency, use `mb_replace_path` in
`mbuild.local.mettle` instead.

## --force

`--force` ignores every up-to-date stamp: programs, tests, C objects and C
libraries are all built again.

```text
$ mbuild build --force
   Resolving dependencies
   Compiling vecmath (C, 1 file)
   Compiling vm (linux, debug)
    Finished in 0.0s
```

To move dependencies, use `mbuild update`.

## clean

```text
$ mbuild clean
     Removed build
     Removed .mbuild/cache
     Removed .mbuild/stamps
     Removed .mbuild/tmp
```

`mbuild clean` removes the outputs, the C cache and every stamp, so the next
build and test run compile everything. Extracted packages stay.

`mbuild clean --all` removes `build/` and all of `.mbuild/`. The next build
extracts the packages again from the download cache, which `clean` never
touches.
