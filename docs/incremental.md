# Incremental builds

The Mettle compiler builds a whole program at once, so mbuild reuses whole
programs (per bin, target and profile) plus one object per C source file.
An unchanged program prints `Fresh` and runs no compiler:

```text
$ mbuild build
       Fresh hello (linux, debug)
    Finished in 0.0s
```

## What triggers a rebuild

A program rebuilds when any of these change:

- the compiler, or its arguments (profile settings, `--set`, `--flag`);
- the target, profile or bin;
- the content of any file in its import graph, standard library and
  generated component selectors included, or of a file embedded with
  `import_str`;
- an import that didn't resolve starting to resolve;
- a library copied beside the binary.

File contents count, not timestamps:

```text
$ touch src/main.mettle && mbuild build
       Fresh hello (linux, debug)
    Finished in 0.0s
$ echo '// note' >> src/main.mettle && mbuild build
   Compiling hello (linux, debug)
    Finished in 0.0s
```

Moving the project doesn't rebuild it. Switching compilers does, including
switching between Linux mbuild and `mbuild.exe` under wine. Switching a
component impl rebuilds exactly the bins that use it. A failed or
interrupted build never counts as done.

Not tracked: system libraries (`mb_link_libs`, pkg-config) and environment
variables. After upgrading a system library, build with `--force`.

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

Programs that aren't Fresh compile in parallel, up to `-j N`
(`MBUILD_JOBS`, default 8); their output is printed in order. After a
failure no new compile starts.

## C objects

A C source recompiles when it, a header it includes, its flags or the C
compiler change. The package's library is relinked only when an object
changed, and a C change that produces the same library leaves the program
Fresh:

```text
$ echo '/* x */' >> .mbuild/deps/vecmath/csrc/include/vec.h
$ mbuild build
   Compiling vecmath (C, 1 file)
       Fresh vm (linux, debug)
    Finished in 0.0s
```

## Tests

`mbuild test` caches like `go test`: a test file that passed isn't run again
until it, anything it imports, the compiler, the target or the `mettle test`
arguments (including `--filter`) change. Failing files are never cached.

```text
$ mbuild test
ok     src/shout.mettle (1 passed)
test result: ok. 1 passed, 0 cached, 0 failed in 0.0s
$ mbuild test
ok     src/shout.mettle (cached)
test result: ok. 0 passed, 1 cached, 0 failed in 0.0s
```

Test files are your project's `.mettle` files with an `@test` function.
mbuild skips dot directories, `build/` directories, path packages and nested
projects (a subdirectory with its own `mbuild.mettle`); run `mbuild test`
inside a nested project to test it.

Test programs ([project](project.md#test-programs)) are cached the same way,
by their build inputs.

`mettle test` runs tests in the compiler's interpreter, which can't call C.
When a test that reaches an `extern` fails, mbuild says so:

```text
FAILED src/e_test.mettle
note: `mettle test` runs tests in the compiler's interpreter, which cannot call C functions: the externs this file reaches (say_c) give an undefined result there. Test code that needs them in a test program (mb_test_bin, docs/project.md).
```

## Dependencies

While `mbuild.lock` and the requirements are unchanged and the extracted
packages are the locked versions, mbuild touches no registry
(`dependencies: mbuild.lock unchanged, packages in place` under `-v`).
Otherwise it resolves, keeps every lock pin that still fits, and extracts
only packages whose version changed, from the download cache when it can.

This check looks at versions, not files: edits inside `.mbuild/deps/` stay
until the version changes or `mbuild clean --all`. To work on a dependency,
use `mb_replace_path` in `mbuild.local.mettle`.

## --force and clean

`--force` rebuilds everything: programs, tests, C objects and libraries. It
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
