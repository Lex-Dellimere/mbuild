# incremental builds

the mettle compiler builds a whole program at once, so mbuild reuses whole
programs (per bin, target and profile) plus one object per C source file.
an unchanged program prints `Fresh` and runs no compiler:

```text
$ mbuild build
       Fresh hello (linux, debug)
    Finished in 0.0s
```

## what triggers a rebuild

a program rebuilds when any of these change:

- the compiler, or its arguments (profile settings, `--set`, `--flag`);
- the target, profile or bin;
- the content of any file in its import graph, standard library and
  generated component selectors included, or of a file embedded with
  `import_str`;
- an import that didn't resolve starting to resolve;
- a library copied beside the binary.

file contents count, not timestamps:

```text
$ touch src/main.mettle && mbuild build
       Fresh hello (linux, debug)
    Finished in 0.0s
$ echo '// note' >> src/main.mettle && mbuild build
   Compiling hello (linux, debug)
    Finished in 0.0s
```

moving the project doesn't rebuild it. switching compilers does, including
switching between linux mbuild and `mbuild.exe` under wine. switching a
component impl rebuilds exactly the bins that use it. a failed or
interrupted build never counts as done.

not tracked: system libraries (`mb_link_libs`, pkg-config) and environment
variables. after upgrading a system library, build with `--force`.

`-v` says how mbuild decided:

```text
$ mbuild -v build
  > mettle for linux: /home/you/Mettle/bin/mettle ($METTLE)
  > dependencies: mbuild.lock unchanged, packages in place
...
  > fresh: .mbuild/cache/linux/c/vecmath/csrc/vec.c.o
       Fresh vm (linux, debug)
    Finished in 0.0s
```

programs that aren't Fresh compile in parallel, up to `-j N`
(`MBUILD_JOBS`, default 8); their output is printed in order. after a
failure no new compile starts.

## C objects

a C source recompiles when it, a header it includes, its flags or the C
compiler change. the package's library is relinked only when an object
changed, and a C change that produces the same library leaves the program
Fresh:

```text
$ echo '/* x */' >> .mbuild/deps/vecmath/csrc/include/vec.h
$ mbuild build
   Compiling vecmath (C, 1 file)
       Fresh vm (linux, debug)
    Finished in 0.0s
```

## tests

`mbuild test` caches like `go test`: a (test, cell) that passed isn't run
again until its build inputs (the file, anything it imports, the compiler,
the target, the flags), its test settings or its golden files change.
failures are never cached; `--force`, `--bless` and `--repeat` above 1 run
everything.

```text
$ mbuild test
test src/shout.mettle (debug) ... ok  0.0s  1 check
test result: ok. 1 passed, 0 failed, 1 check (0.0s)
$ mbuild test
test src/shout.mettle (debug) ... ok (cached)
test result: ok. 1 passed, 0 failed, 1 cached (0.0s)
```

test files are your project's `.mettle` files with an `@test` function.
mbuild skips dot directories, `build/` directories, path packages and nested
projects (a subdirectory with its own `mbuild.mettle`); run `mbuild test`
inside a nested project to test it. test programs and the rest:
[project](project.md#tests).

## dependencies

while `mbuild.lock` and the requirements are unchanged and the extracted
packages are the locked versions, mbuild touches no registry
(`dependencies: mbuild.lock unchanged, packages in place` under `-v`).
otherwise it resolves, keeps every lock pin that still fits, and extracts
only packages whose version changed, from the download cache when it can.

this check looks at versions, not files: edits inside `.mbuild/deps/` stay
until the version changes or `mbuild clean --all`. to work on a dependency,
use `mb_replace_path` in `mbuild.local.mettle`.

## --force and clean

`--force` rebuilds everything: programs, tests, C objects and libraries. it
doesn't move dependencies; `mbuild update` does.

```text
$ mbuild clean
     Removed build
     Removed .mbuild/cache
     Removed .mbuild/stamps
     Removed .mbuild/tmp
```

`mbuild clean` removes the outputs, the C cache and every stamp; extracted
packages stay. `mbuild clean --all` removes all of `.mbuild/` too, and the
next build extracts the packages again from the download cache.
