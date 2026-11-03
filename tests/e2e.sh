#!/bin/sh
# e2e.sh: end-to-end checks of mbuild on real projects.
#
#   tests/e2e.sh              all scenarios (Linux host, then Windows under wine)
#   E2E_NO_WINE=1 tests/e2e.sh   skip the wine scenarios
#
# Bootstraps mbuild with the head compiler ($METTLE, default ../Mettle/bin/mettle),
# then works in fresh projects under /tmp/opencode/e2e-*.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
export METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
METTLE_W017="${METTLE_W017:-$HOME/.mbuild/toolchains/v0.17.0/windows/mettle.exe}"
export WINEDEBUG=-all
export NO_COLOR=1
unset MBUILD_COLOR

T=/tmp/opencode
pass=0
fail=0
failed_names=""

ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() {
  fail=$((fail + 1)); failed_names="$failed_names
  $1"; echo "FAIL $1"
  if [ -n "${2:-}" ]; then echo "$2" | sed 's/^/     | /' | head -40; fi
}
check() { # name, command...
  name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
contains() { # name, haystack, needle
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected [$3] in:
$2" ;; esac
}
lacks() { # name, haystack, needle
  case "$2" in *"$3"*) bad "$1" "did not expect [$3] in:
$2" ;; *) ok "$1" ;; esac
}
code_is() { # name, got, want, output
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (exit $2, want $3)" "${4:-}"; fi
}
fresh_dir() {
  d="$T/e2e-$1"
  rm -rf "$d"; mkdir -p "$d"; echo "$d"
}

# ---------------------------------------------------------------------------
echo "== bootstrap (head compiler: $METTLE)"
out=$(cd "$here" && mkdir -p build/stage0 && "$METTLE" --build src/main.mettle -o build/stage0/mbuild >/dev/null && build/stage0/mbuild build -r -t host --mettle "$METTLE" 2>&1); rc=$?
code_is "stage 0 mettle, then mbuild builds mbuild" "$rc" 0 "$out"
[ $rc = 0 ] || { echo "e2e: bootstrap failed; stopping"; exit 1; }
out=$(mkdir -p "$T/e2e-core" && "$METTLE" --build "$here/tests/core_graph.mettle" -o "$T/e2e-core/core_graph" >/dev/null 2>&1 && "$T/e2e-core/core_graph" 2>&1); rc=$?
code_is "core_graph" "$rc" 0 "$out"
MB="$T/e2e-mbuild"
cp "$here/build/linux/release/mbuild" "$MB"
[ -x "$MB" ] || { echo "no mbuild binary"; exit 1; }

# ---------------------------------------------------------------------------
echo "== init / build / run"
P=$(fresh_dir app)
cd "$P"
out=$("$MB" init app 2>&1); rc=$?
code_is "init" "$rc" 0 "$out"
check "init wrote mbuild.toml" grep -q 'name = "app"' mbuild.toml
check "init wrote src/main.mettle" test -f src/main.mettle
check "init wrote .gitignore" grep -qx '/.mbuild/' .gitignore
out=$("$MB" init 2>&1); rc=$?
code_is "init refuses to overwrite" "$rc" 1 "$out"

out=$("$MB" build 2>&1); rc=$?
code_is "first build" "$rc" 0 "$out"
contains "first build says Compiling" "$out" "Compiling app (linux, debug)"
contains "first build says Finished" "$out" "Finished"
out=$(./build/linux/debug/app 2>&1)
contains "binary runs" "$out" "Hello from app!"
check "no intermediate object left" test ! -e build/linux/debug/app.o

before=$(stat -c %y build/linux/debug/app)
out=$("$MB" -v build 2>&1); rc=$?
code_is "second build" "$rc" 0 "$out"
contains "second build is Fresh" "$out" "Fresh app (linux, debug)"
lacks "second build does not run the compiler" "$out" "--build"
after=$(stat -c %y build/linux/debug/app)
check "second build leaves the binary alone" test "$before" = "$after"

# An imported module and an embedded file.
cat > src/main.mettle <<'EOF'
import "std/io";
import "util";

fn main(argc: int32, argv: cstring*) -> int32 {
  print(greeting());
  print(import_str "banner.txt");
  return argc - 1;
}
EOF
cat > src/util.mettle <<'EOF'
export fn greeting() -> string {
  return "greeting v1\n";
}
EOF
echo "banner one" > src/banner.txt
out=$("$MB" build 2>&1); rc=$?
code_is "build with import + import_str" "$rc" 0 "$out"
out=$(./build/linux/debug/app)
contains "imported module used" "$out" "greeting v1"
contains "embedded file used" "$out" "banner one"
out=$("$MB" build 2>&1)
contains "unchanged: Fresh" "$out" "Fresh app"

sed -i 's/greeting v1/greeting v2/' src/util.mettle
out=$("$MB" build 2>&1)
contains "changing an imported file rebuilds" "$out" "Compiling app"
contains "rebuilt binary has the change" "$(./build/linux/debug/app)" "greeting v2"

echo "banner two" > src/banner.txt
out=$("$MB" build 2>&1)
contains "changing an import_str file rebuilds" "$out" "Compiling app"
contains "rebuilt binary has the new embed" "$(./build/linux/debug/app)" "banner two"

out=$("$MB" build --force 2>&1)
contains "--force rebuilds" "$out" "Compiling app"

out=$("$MB" build -r 2>&1); rc=$?
code_is "release build" "$rc" 0 "$out"
contains "release build label" "$out" "Compiling app (linux, release)"
check "release binary exists" test -x build/linux/release/app
out=$("$MB" -v build --release 2>&1)
contains "release build Fresh" "$out" "Fresh app (linux, release)"
out=$("$MB" -v build -r --force 2>&1)
contains "release passes --release to the compiler" "$out" "--release"

out=$("$MB" run -- a b c 2>&1); rc=$?
code_is "run propagates the exit code" "$rc" 3 "$out"
contains "run prints Running" "$out" "Running build/linux/debug/app"
contains "run shows program output" "$out" "greeting v2"

out=$("$MB" biuld 2>&1); rc=$?
code_is "unknown command fails" "$rc" 1 "$out"
contains "unknown command suggests" "$out" "mbuild build"
out=$("$MB" build --forse 2>&1); rc=$?
contains "unknown flag suggests" "$out" "--force"
out=$("$MB" help build 2>&1)
contains "help build" "$out" "usage: mbuild build"

# ---------------------------------------------------------------------------
echo "== test"
cat > src/calc.mettle <<'EOF'
export fn add(a: int32, b: int32) -> int32 {
  return a + b;
}

@test fn adds() -> int32 {
  if (add(2, 2) != 4) { return 1; }
  return 0;
}

@test fn adds_zero() -> int32 {
  if (add(0, 5) != 5) { return 1; }
  return 0;
}
EOF
out=$("$MB" test 2>&1); rc=$?
code_is "test passes" "$rc" 0 "$out"
contains "test reports ok" "$out" "ok     src/calc.mettle (2 passed)"
out=$("$MB" test 2>&1); rc=$?
code_is "test cached passes" "$rc" 0 "$out"
contains "test is cached" "$out" "src/calc.mettle (cached)"
out=$("$MB" test --filter zero 2>&1)
contains "test --filter runs a subset" "$out" "(1 passed)"
out=$("$MB" test --force 2>&1)
lacks "test --force ignores the cache" "$out" "(cached)"
cat > src/broken_test.mettle <<'EOF'
@test fn fails() -> int32 {
  return 7;
}
EOF
out=$("$MB" test 2>&1); rc=$?
code_is "failing test exits 1" "$rc" 1 "$out"
contains "failing test is named" "$out" "FAILED src/broken_test.mettle"
contains "passing file stays cached" "$out" "src/calc.mettle (cached)"
contains "test summary" "$out" "test result: FAILED"
out=$("$MB" test src/calc.mettle 2>&1); rc=$?
code_is "test with an explicit file" "$rc" 0 "$out"
rm src/broken_test.mettle

# ---------------------------------------------------------------------------
echo "== check / clean"
out=$("$MB" check 2>&1); rc=$?
code_is "check passes" "$rc" 0 "$out"
contains "check says Checking" "$out" "Checking app (linux)"
check "check leaves no object" test ! -e .mbuild/tmp/check-app.o
cp src/util.mettle src/util.keep
printf 'export fn greeting() -> string {\n  return undefined_name;\n}\n' > src/util.mettle
out=$("$MB" check 2>&1); rc=$?
code_is "check fails on an error" "$rc" 1 "$out"
contains "check shows the compiler error" "$out" "undefined_name"
out=$("$MB" build 2>&1); rc=$?
code_is "build fails on an error" "$rc" 1 "$out"
contains "build failure names the bin" "$out" "could not compile \`app\`"
mv src/util.keep src/util.mettle
out=$("$MB" build 2>&1); rc=$?
code_is "build recovers" "$rc" 0 "$out"

out=$("$MB" clean 2>&1); rc=$?
code_is "clean" "$rc" 0 "$out"
check "clean removed build/" test ! -e build
check "clean removed stamps" test ! -e .mbuild/stamps
out=$("$MB" build 2>&1)
contains "build after clean compiles" "$out" "Compiling app"
out=$("$MB" clean --all 2>&1)
check "clean --all removed .mbuild" test ! -e .mbuild

# ---------------------------------------------------------------------------
echo "== multiple bins"
P=$(fresh_dir multi)
cd "$P"
printf '[package]\nname = "multi"\n' > mbuild.toml
mkdir -p src cmd/tool cmd/other
printf 'import "std/io";\nfn main() -> int32 {\n  print("main bin\\n");\n  return 0;\n}\n' > src/main.mettle
printf 'import "std/io";\nfn main() -> int32 {\n  print("tool bin\\n");\n  return 0;\n}\n' > cmd/tool/main.mettle
printf 'import "std/io";\nfn main() -> int32 {\n  print("other bin\\n");\n  return 0;\n}\n' > cmd/other/main.mettle
out=$("$MB" build 2>&1); rc=$?
code_is "multi-bin build" "$rc" 0 "$out"
check "bin multi" test -x build/linux/debug/multi
check "bin tool" test -x build/linux/debug/tool
check "bin other" test -x build/linux/debug/other
contains "tool runs" "$(./build/linux/debug/tool)" "tool bin"
out=$("$MB" run tool 2>&1)
contains "run picks a bin" "$out" "tool bin"
out=$("$MB" run 2>&1)
contains "run defaults to the package bin" "$out" "main bin"
out=$("$MB" build toool 2>&1); rc=$?
code_is "unknown bin fails" "$rc" 1 "$out"
contains "unknown bin suggests" "$out" "did you mean \`tool\`"
out=$("$MB" build other 2>&1)
contains "build one bin" "$out" "other (linux, debug)"
lacks "build one bin only" "$out" "tool (linux"
# Parallel compiles: three bins at once, output in a stable order.
printf 'fn main() -> int32 {\n  return undefined_a;\n}\n' > cmd/tool/main.mettle
printf 'fn main() -> int32 {\n  return undefined_b;\n}\n' > cmd/other/main.mettle
out=$("$MB" build -j 4 --force 2>&1); rc=$?
code_is "parallel build with two broken bins fails" "$rc" 1 "$out"
contains "parallel: the first broken bin is reported" "$out" "could not compile \`other\`"
contains "parallel: the second broken bin is reported" "$out" "could not compile \`tool\`"
first_a=$(echo "$out" | grep -n "undefined_b" | head -1 | cut -d: -f1)
first_b=$(echo "$out" | grep -n "undefined_a" | head -1 | cut -d: -f1)
check "parallel: outputs in bin order (other before tool)" test "${first_a:-0}" -lt "${first_b:-0}"
printf 'import "std/io";\nfn main() -> int32 {\n  print("tool bin\\n");\n  return 0;\n}\n' > cmd/tool/main.mettle
printf 'import "std/io";\nfn main() -> int32 {\n  print("other bin\\n");\n  return 0;\n}\n' > cmd/other/main.mettle
out=$("$MB" build -j 4 2>&1); rc=$?
code_is "parallel build" "$rc" 0 "$out"
contains "parallel build: tool runs" "$(./build/linux/debug/tool)" "tool bin"
contains "parallel build: other runs" "$(./build/linux/debug/other)" "other bin"
out=$("$MB" build -j 1 --force 2>&1); rc=$?
code_is "sequential build (-j 1)" "$rc" 0 "$out"
out=$("$MB" build -j 4 2>&1)
contains "parallel: then Fresh" "$out" "Fresh tool (linux, debug)"

# ---------------------------------------------------------------------------
echo "== manifest warnings and errors"
P=$(fresh_dir typo)
cd "$P"
printf '[package]\nname = "typo"\n\n[biuld]\ntargets = ["linux"]\n\n[build]\nflagz = []\n' > mbuild.toml
mkdir src
printf 'fn main() -> int32 {\n  return 0;\n}\n' > src/main.mettle
out=$("$MB" build 2>&1); rc=$?
code_is "build with typos still works" "$rc" 0 "$out"
contains "unknown section warning" "$out" "did you mean [build]"
contains "unknown key warning" "$out" "did you mean 'flags'"
contains "warning names the line" "$out" "mbuild.toml:4"
printf '[package]\nversion = "1.0.0"\n' > mbuild.toml
out=$("$MB" build 2>&1); rc=$?
code_is "manifest error fails" "$rc" 1 "$out"
contains "manifest error message" "$out" "name is required"
contains "manifest error hint points at docs/manifest.md" "$out" "docs/manifest.md"
lacks "manifest error hint does not mention DESIGN.md" "$out" "DESIGN.md"
contains "manifest error names the file relative to the cwd" "$out" "error: mbuild.toml:"
mkdir -p sub
out=$(cd sub && "$MB" build 2>&1)
contains "manifest error from a subdirectory: relative path" "$out" "error: ../mbuild.toml:"
printf '[package]\nname = "typo"\n' > mbuild.toml
out=$("$MB" build -p fast 2>&1); rc=$?
code_is "unknown profile fails" "$rc" 1 "$out"
out=$("$MB" build -t linux,windoes 2>&1); rc=$?
contains "unknown target suggests" "$out" "did you mean \`windows\`"

echo "== missing remote import"
P=$(fresh_dir missing)
cd "$P"
printf '[package]\nname = "missing"\n' > mbuild.toml
mkdir src
printf 'import "std/io";\nimport "github.com/nobody/none/thing";\nfn main() -> int32 {\n  return 0;\n}\n' > src/main.mettle
out=$("$MB" build --locked 2>&1); rc=$?
code_is "--locked missing module fails" "$rc" 1 "$out"
contains "missing import names file:line" "$out" "src/main.mettle:2"
contains "missing import hints mbuild get" "$out" "mbuild get github.com/nobody/none"
check "--locked leaves mbuild.toml alone" test "$(cat mbuild.toml)" = "$(printf '[package]\nname = "missing"\n')"
out=$("$MB" build --offline 2>&1); rc=$?
code_is "--offline missing module fails" "$rc" 1 "$out"

if command -v git >/dev/null 2>&1; then
  echo "== auto-detected dependency (local git base)"
  G="$T/e2e-gitbase"
  rm -rf "$G" "$T/e2e-mbhome"
  mkdir -p "$G/github.com/test/lib"
  (cd "$G/github.com/test/lib" && git init -q &&
    printf 'export fn hello() -> string {\n  return "hello from lib\\n";\n}\n' > hello.mettle &&
    printf '[package]\nname = "lib"\nmodule = "github.com/test/lib"\n' > mbuild.toml &&
    git add . && git -c user.email=e2e@x -c user.name=e2e commit -qm init && git tag v1.0.0)
  P=$(fresh_dir autodep)
  cd "$P"
  "$MB" init autodep >/dev/null 2>&1
  printf 'import "std/io";\nimport "github.com/test/lib/hello";\nfn main() -> int32 {\n  print(hello());\n  return 0;\n}\n' > src/main.mettle
  out=$(MBUILD_HOME="$T/e2e-mbhome" MBUILD_GIT_BASE="$G" "$MB" run 2>&1); rc=$?
  code_is "auto-added dependency builds" "$rc" 0 "$out"
  contains "auto-added dependency runs" "$out" "hello from lib"
  check "auto-added dependency is in mbuild.toml" grep -q 'github.com/test/lib' mbuild.toml
  out=$(MBUILD_HOME="$T/e2e-mbhome" MBUILD_GIT_BASE="$G" "$MB" build 2>&1)
  contains "dependency build then Fresh" "$out" "Fresh autodep"

  echo "== imports into selected modules, tidy (fixtures)"
  FX="$T/e2e-fx"
  sh "$here/tests/fixtures/make-fixtures.sh" "$FX" >/dev/null 2>&1
  fx() { MBUILD_HOME="$FX/home" MBUILD_GIT_BASE="$FX/gitbase" "$MB" "$@"; }
  cd "$FX/app"
  out=$(fx build -t linux 2>&1); rc=$?
  code_is "fixture app builds" "$rc" 0 "$out"
  out=$(fx tidy 2>&1); rc=$?
  code_is "tidy adds a directly imported, already selected module" "$rc" 0 "$out"
  contains "tidy adds it at the selected version" "$out" "Adding github.com/demo/strutil v1.0.0 (already selected)"
  cp src/main.mettle src/main.keep
  sed -i 's|strutil/strutil"|strutil/strutl"|' src/main.mettle
  out=$(fx build -t linux 2>&1); rc=$?
  code_is "typo'd file in a selected module fails" "$rc" 1 "$out"
  contains "typo'd file: names the module and version" "$out" "github.com/demo/strutil (v1.0.0) has no file 'strutl.mettle'"
  contains "typo'd file: did you mean" "$out" "did you mean \`github.com/demo/strutil/strutil\`"
  contains "typo'd file: lists the files" "$out" "strutil.mettle"
  lacks "typo'd file: not treated as a missing dependency" "$out" "is not a dependency"
  lacks "typo'd file: no fetch of a bogus module" "$out" "Fetching github.com/demo/strutil/strutl"
  sed -i 's|strutil/strutl"|strutil"|' src/main.mettle
  out=$(fx build -t linux 2>&1); rc=$?
  code_is "directory import fails" "$rc" 1 "$out"
  contains "directory import: says it is a package directory" "$out" "package directory"
  contains "directory import: suggests a file" "$out" "github.com/demo/strutil/strutil"
  mv src/main.keep src/main.mettle

  # tidy: a module only a dependency imports, and an alias nothing in the
  # root imports, are dropped; direct imports stay.
  fx_manifest() {
    printf '[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\n"github.com/demo/vecmath" = "v0.1.0"\n"github.com/demo/nomanifest" = "main"\n%s\n' "$1" > mbuild.toml
  }
  fx_manifest '"github.com/demo/strutil" = "v1.0.0"'
  printf 'import "std/io";\nimport "github.com/demo/vecmath/vecmath";\nimport "github.com/demo/nomanifest/greet";\nfn main() -> int32 {\n  println(vm_banner());\n  println(greet("tidy"));\n  return 0;\n}\n' > src/main.mettle
  mkdir -p tools/sub
  printf '[package]\nname = "sub"\n' > tools/sub/mbuild.toml
  printf 'import "github.com/demo/other/thing";\nfn main() -> int32 {\n  return 0;\n}\n' > tools/sub/main.mettle
  out=$(fx tidy 2>&1); rc=$?
  code_is "tidy" "$rc" 0 "$out"
  check "tidy keeps vecmath" grep -q 'github.com/demo/vecmath' mbuild.toml
  check "tidy keeps nomanifest" grep -q 'github.com/demo/nomanifest' mbuild.toml
  check "tidy drops a module only a dependency imports" sh -c '! grep -q "demo/strutil" mbuild.toml'
  check "tidy ignores a nested project's imports" sh -c '! grep -q "demo/other" mbuild.toml'
  out=$(fx build -t linux 2>&1); rc=$?
  code_is "build after tidy" "$rc" 0 "$out"
  fx_manifest 'su = { module = "github.com/demo/strutil", version = "v1.0.0" }'
  out=$(fx tidy 2>&1); rc=$?
  code_is "tidy with an unused alias" "$rc" 0 "$out"
  check "tidy drops an alias only a dependency's module matches" sh -c '! grep -q "^su = " mbuild.toml'
  fx_manifest 'su = { module = "github.com/demo/strutil", version = "v1.0.0" }'
  printf 'import "std/io";\nimport "github.com/demo/vecmath/vecmath";\nimport "github.com/demo/nomanifest/greet";\nimport "su/strutil";\nfn main() -> int32 {\n  println(vm_banner());\n  println(greet(su_version()));\n  return 0;\n}\n' > src/main.mettle
  out=$(fx tidy 2>&1); rc=$?
  code_is "tidy with a used alias" "$rc" 0 "$out"
  check "tidy keeps an alias the root imports" grep -q '^su = ' mbuild.toml
  check "tidy does not add the alias's module again" sh -c '! grep -q "^\"github.com/demo/strutil\"" mbuild.toml'
  out=$(fx run -t linux 2>&1); rc=$?
  code_is "alias build runs" "$rc" 0 "$out"
  contains "alias import works" "$out" "hello, strutil"
fi

# ---------------------------------------------------------------------------
echo "== zero-config"
P=$(fresh_dir zero)
cd "$P"
printf 'import "std/io";\nfn main() -> int32 {\n  print("zero config\\n");\n  return 0;\n}\n' > main.mettle
out=$("$MB" build 2>&1); rc=$?
code_is "zero-config build" "$rc" 0 "$out"
contains "zero-config names the bin after the directory" "$out" "Compiling e2e-zero"
contains "zero-config binary runs" "$(./build/linux/debug/e2e-zero)" "zero config"
check "zero-config wrote no manifest" test ! -e mbuild.toml
P=$(fresh_dir zero2)
cd "$P"
printf 'import "std/io";\nfn main() -> int32 {\n  print("hello file\\n");\n  return 0;\n}\n' > hello.mettle
out=$("$MB" run 2>&1); rc=$?
contains "zero-config single file" "$out" "hello file"

P=$(fresh_dir nothing)
cd "$P"
out=$("$MB" build 2>&1); rc=$?
code_is "nothing to build outside a project fails" "$rc" 1 "$out"
contains "outside a project: suggests mbuild init" "$out" "mbuild init"

# ---------------------------------------------------------------------------
echo "== test flags, nested projects, colour"
P=$(fresh_dir tflags)
cd "$P"
printf '[package]\nname = "tflags"\n\n[build]\nprelude = true\n' > mbuild.toml
mkdir -p src nested/src deep/x/build gen
printf 'fn main() -> int32 {\n  println("prelude main");\n  return 0;\n}\n' > src/main.mettle
printf '@test fn uses_prelude() -> int32 {\n  println("no import needed");\n  return 0;\n}\n' > src/p_test.mettle
out=$("$MB" test 2>&1); rc=$?
code_is "test with [build] prelude = true" "$rc" 0 "$out"
contains "prelude test passes" "$out" "ok     src/p_test.mettle"
out=$("$MB" -v test --force 2>&1)
contains "test passes --prelude" "$out" "--prelude"
printf '[package]\nname = "nested"\n' > nested/mbuild.toml
printf '@test fn nested_fails() -> int32 {\n  return 1;\n}\n' > nested/src/n_test.mettle
printf '@test fn build_fails() -> int32 {\n  return 1;\n}\n' > deep/x/build/b_test.mettle
out=$("$MB" test 2>&1); rc=$?
code_is "nested project and build/ dirs are skipped by test" "$rc" 0 "$out"
lacks "nested project test not run" "$out" "n_test"
lacks "deep build/ test not run" "$out" "b_test"
out=$("$MB" --color=always -v build --force 2>&1)
contains "--color=always passes CLICOLOR_FORCE" "$out" "CLICOLOR_FORCE=1"
out=$("$MB" --color always -v build --force 2>&1); rc=$?
code_is "--color always (space) works" "$rc" 0 "$out"
contains "--color always (space) passes CLICOLOR_FORCE" "$out" "CLICOLOR_FORCE=1"
out=$("$MB" --color never -v build --force 2>&1); rc=$?
code_is "--color never (space) works" "$rc" 0 "$out"
contains "--color never passes NO_COLOR" "$out" "NO_COLOR=1"
lacks "--color never: no CLICOLOR_FORCE" "$out" "CLICOLOR_FORCE"
out=$(LANG=C.UTF-8 LC_ALL= LC_CTYPE= "$MB" --color always -v build --force 2>&1)
contains "UTF-8 locale passes METTLE_DIAG_UNICODE" "$out" "METTLE_DIAG_UNICODE=1"
out=$(LANG=C LC_ALL= LC_CTYPE= "$MB" --color always -v build --force 2>&1)
lacks "non-UTF-8 locale: no METTLE_DIAG_UNICODE" "$out" "METTLE_DIAG_UNICODE"
out=$("$MB" -v build 2>&1)
contains "colour settings do not invalidate the build" "$out" "Fresh tflags"
printf 'fn main() -> int32 {\n  return undefined_name;\n}\n' > src/main.mettle
out=$("$MB" --color always build 2>&1)
contains "--color always: compiler diagnostics are coloured" "$out" "$(printf '\033')[2m[E0003]"
contains "the coloured error still names the bin" "$out" "could not compile"

echo "== library package"
P=$(fresh_dir lib)
cd "$P"
printf '[package]\nname = "mylib"\n' > mbuild.toml
mkdir src
printf 'export fn add(a: int32, b: int32) -> int32 {\n  return a + b;\n}\n' > src/lib.mettle
printf 'export fn twice(a: int32) -> int32 {\n  return a * 2;\n}\n' > helpers.mettle
printf 'import "src/lib";\n@test fn adds() -> int32 {\n  if (add(1, 2) != 3) { return 1; }\n  return 0;\n}\n' > lib_test.mettle
out=$("$MB" check 2>&1); rc=$?
code_is "library check" "$rc" 0 "$out"
contains "library check: src file" "$out" "Checking src/lib (linux)"
contains "library check: top-level file" "$out" "Checking helpers (linux)"
lacks "library check skips test files" "$out" "lib_test"
check "library check leaves no object" sh -c '! ls .mbuild/tmp/*.o 2>/dev/null | grep -q .'
out=$("$MB" build 2>&1); rc=$?
code_is "library build" "$rc" 0 "$out"
contains "library build: nothing to link" "$out" "library: nothing to link"
out=$("$MB" run 2>&1); rc=$?
code_is "library run fails" "$rc" 1 "$out"
contains "library run explains" "$out" "is a library"
out=$("$MB" test 2>&1); rc=$?
code_is "library test" "$rc" 0 "$out"
printf 'export fn add(a: int32, b: int32) -> int32 {\n  return a + missing_b;\n}\n' > src/lib.mettle
out=$("$MB" check 2>&1); rc=$?
code_is "library check fails on an error" "$rc" 1 "$out"
contains "library check shows the error" "$out" "missing_b"

echo "== test of code with externs"
P=$(fresh_dir externs)
cd "$P"
printf '[package]\nname = "ext"\n' > mbuild.toml
printf 'extern fn mbx_answer() -> int32 = "mbx_answer";\n@test fn answer() -> int32 {\n  if (mbx_answer() != 42) { return 1; }\n  return 0;\n}\n' > e_test.mettle
out=$("$MB" test 2>&1); rc=$?
code_is "extern test fails" "$rc" 1 "$out"
contains "extern test: note about the interpreter" "$out" "cannot call C functions"
contains "extern test: names the extern" "$out" "mbx_answer"

# ---------------------------------------------------------------------------
echo "== compiler shortcuts"
out=$("$MB" mettle -- --version 2>&1); rc=$?
code_is "mettle -- --version" "$rc" 0 "$out"
contains "mettle --version output" "$out" "mettle v"
out=$("$MB" explain E0003 2>&1); rc=$?
code_is "explain E0003" "$rc" 0 "$out"
contains "explain output" "$out" "E0003"
out=$("$MB" version 2>&1)
contains "version" "$out" "mbuild 0.1.0"
out=$("$MB" doctor -t linux 2>&1); rc=$?
contains "doctor shows the host" "$out" "host"
contains "doctor shows the compiler" "$out" "linux"
contains "doctor shows the Windows C compiler" "$out" "cc windows"
contains "doctor shows pkg-config" "$out" "pkg-config"
contains "doctor shows curl" "$out" "curl"
P=$(fresh_dir pin)
cd "$P"
printf '[package]\nname = "pin"\n\n[toolchain]\nmettle = "v0.16.0"\n' > mbuild.toml
out=$("$MB" doctor -t linux --offline 2>&1)
contains "doctor warns when the pin differs from \$METTLE" "$out" "pins a different compiler than \$METTLE"
out=$("$MB" help toolchain 2>&1)
contains "help toolchain lists remove" "$out" "remove VERSION"

# ---------------------------------------------------------------------------
echo "== self-host"
P=$(fresh_dir self)
cp -r "$here/src" "$here/mbuild.toml" "$P/"
cd "$P"
out=$("$MB" build -t host 2>&1); rc=$?
code_is "mbuild builds itself" "$rc" 0 "$out"
out=$(./build/linux/debug/mbuild version 2>&1)
contains "self-built mbuild runs" "$out" "mbuild 0.1.0"
out=$(./build/linux/debug/mbuild build -t host 2>&1); rc=$?
code_is "self-built mbuild builds itself" "$rc" 0 "$out"
contains "self-built mbuild sees it Fresh" "$out" "Fresh mbuild (linux, debug)"
# The head compiler's --release currently dies with an internal error on
# toml.mettle (global_access in tml_scalar); the v0.17.0 release does not.
L017="$HOME/.mbuild/toolchains/v0.17.0/linux/bin/mettle"
if [ -x "$L017" ]; then
  out=$(MBUILD_METTLE_LINUX="$L017" "$MB" build -r -t host 2>&1); rc=$?
  code_is "self-host release (v0.17.0 compiler)" "$rc" 0 "$out"
  contains "self-host release binary runs" "$(./build/linux/release/mbuild version 2>&1)" "mbuild 0.1.0"
fi

# ---------------------------------------------------------------------------
if [ "${E2E_NO_WINE:-}" = "1" ] || ! command -v wine >/dev/null 2>&1 || [ ! -f "$METTLE_W017" ]; then
  echo "== wine: skipped"
else
  echo "== wine: mbuild.exe built by the v0.17.0 Windows compiler"
  W="$T/e2e-wine-mbuild"
  rm -rf "$W"; mkdir -p "$W"
  cp -r "$here/src" "$W/"
  out=$(cd "$W" && wine "$METTLE_W017" --build src/main.mettle -o mbuild.exe 2>&1); rc=$?
  code_is "bootstrap mbuild.exe under wine" "$rc" 0 "$out"
  WMB="$W/mbuild.exe"
fi
if [ -f "${WMB:-/nonexistent}" ]; then
  WMETTLE="Z:$(echo "$METTLE_W017" | tr '/' '\\')"
  wmb() { METTLE="$WMETTLE" wine "$WMB" "$@"; }

  P=$(fresh_dir wapp)
  cd "$P"
  out=$(wmb init wapp 2>&1); rc=$?
  code_is "wine: init" "$rc" 0 "$out"
  out=$(wmb version 2>&1)
  contains "wine: version reports windows" "$out" "windows"
  out=$(wmb build 2>&1); rc=$?
  code_is "wine: build" "$rc" 0 "$out"
  contains "wine: builds the windows target" "$out" "Compiling wapp (windows, debug)"
  check "wine: exe exists" test -f build/windows/debug/wapp.exe
  check "wine: no intermediate object" test ! -e build/windows/debug/wapp.obj
  contains "wine: exe runs" "$(wine build/windows/debug/wapp.exe 2>&1)" "Hello from wapp!"
  out=$(wmb build 2>&1)
  contains "wine: second build Fresh" "$out" "Fresh wapp (windows, debug)"
  cat > src/main.mettle <<'EOF'
import "std/io";
import "util";

fn main(argc: int32, argv: cstring*) -> int32 {
  print(greeting());
  return argc - 1;
}
EOF
  printf 'export fn greeting() -> string {\n  return "wine v1\\n";\n}\n' > src/util.mettle
  out=$(wmb build 2>&1)
  contains "wine: change rebuilds" "$out" "Compiling wapp"
  out=$(wmb run -- x y 2>&1); rc=$?
  code_is "wine: run exit code" "$rc" 2 "$out"
  contains "wine: run output" "$out" "wine v1"
  printf '@test fn t() -> int32 {\n  return 0;\n}\n' > src/t_test.mettle
  out=$(wmb test 2>&1); rc=$?
  code_is "wine: test" "$rc" 0 "$out"
  out=$(wmb test 2>&1)
  contains "wine: test cached" "$out" "(cached)"
  out=$(wmb check 2>&1); rc=$?
  code_is "wine: check" "$rc" 0 "$out"
  out=$(wmb clean 2>&1); rc=$?
  check "wine: clean" test ! -e build
  out=$(wmb mettle -- --version 2>&1)
  contains "wine: mettle --version" "$out" "mettle v"

fi
if [ -f "${WMB:-/nonexistent}" ]; then
  echo "== Linux mbuild builds the windows target"
  P=$(fresh_dir cross)
  cd "$P"
  "$MB" init cross >/dev/null 2>&1
  out=$("$MB" build -t all 2>&1); rc=$?
  code_is "build -t all" "$rc" 0 "$out"
  check "linux binary" test -x build/linux/debug/cross
  check "windows binary" test -f build/windows/debug/cross.exe
  out=$("$MB" run -t windows 2>&1); rc=$?
  contains "run -t windows through wine" "$out" "Hello from cross!"

  echo "== Linux mbuild and mbuild.exe under wine share stamps"
  if [ -x "$L017" ]; then
    xenv() { MBUILD_METTLE_LINUX="$L017" MBUILD_METTLE_WINDOWS="$METTLE_W017" "$@"; }
    out=$(xenv "$MB" build -t all 2>&1); rc=$?
    code_is "cross-host: Linux build -t all" "$rc" 0 "$out"
    out=$(xenv wine "$WMB" build -t all 2>&1); rc=$?
    code_is "cross-host: wine build -t all" "$rc" 0 "$out"
    contains "cross-host: wine sees linux Fresh" "$out" "Fresh cross (linux, debug)"
    contains "cross-host: wine sees windows Fresh" "$out" "Fresh cross (windows, debug)"
    out=$(xenv "$MB" build -t all 2>&1)
    contains "cross-host: Linux again Fresh" "$out" "Fresh cross (windows, debug)"
    if [ -d "${FX:-/nonexistent}/app" ]; then
      cd "$FX/app"
      xfx() { MBUILD_HOME="$FX/home" MBUILD_GIT_BASE="$FX/gitbase" xenv "$@"; }
      out=$(xfx "$MB" build -t all 2>&1); rc=$?
      code_is "cross-host (native code): Linux build -t all" "$rc" 0 "$out"
      out=$(xfx wine "$WMB" build -t all 2>&1); rc=$?
      code_is "cross-host (native code): wine build -t all" "$rc" 0 "$out"
      lacks "cross-host (native code): wine compiles nothing" "$out" "Compiling"
      out=$(xfx "$MB" build -t all 2>&1)
      lacks "cross-host (native code): Linux again compiles nothing" "$out" "Compiling"
    fi
  fi
fi

# ---------------------------------------------------------------------------
echo
echo "e2e: $pass passed, $fail failed"
if [ $fail -gt 0 ]; then
  echo "failed:$failed_names"
  exit 1
fi
exit 0
