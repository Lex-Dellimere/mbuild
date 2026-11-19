#!/bin/sh
# test_runner.sh: `mbuild test` end to end (settings, matrix, repeat, timeouts, fixtures, golden files), mbuild built debug and --release.
#   METTLE=dev-compiler sh tests/e2e/test_runner.sh   (scratch: $MBTEST_TMP)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
S="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/test_runner}"
rm -rf "$S"
mkdir -p "$S"
export LC_ALL=C NO_COLOR=1 METTLE
unset MBUILD_COLOR
export MBUILD_HOME="$S/home"

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -40; }
check() { name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$S/last.out" 2>/dev/null)"; fi; }
has() { grep -qF -- "$1" "$S/last.out"; }
hasnt() { ! grep -qF -- "$1" "$S/last.out"; }
line() { grep -qxF -- "$1" "$S/last.out"; }
code_is() { [ "$(cat "$S/last.code")" = "$1" ]; }
mb() { "$MB" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }

# proj DIR: a project named after DIR; stdin holds extra lines of fn project()
proj() {
  mkdir -p "$1/src" "$1/tests"
  { printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("%s", "0.1.0");\n' "$(basename "$1")"; cat; printf '}\n'; } > "$1/mbuild.mettle"
}
# prog FILE CODE [LINE]: a test program printing LINE (default PASS one) and returning CODE
prog() { printf 'import "std/io";\nfn main() -> int32 {\n  println("%s");\n  return %s;\n}\n' "${3:-PASS one}" "$2" > "$1"; }

# unit NAME: tests/unit/NAME.mettle built debug and --release, both runs agree
unit() { if out=$(METTLE="$METTLE" TMPDIR="$S" sh "$here/tools/mcheck.sh" "$here/tests/unit/$1.mettle" --run 2>&1); then ok "$1 ($(printf '%s\n' "$out" | sed -n 's/^\[run\] ok (.*: \(.*\))$/\1/p'))"; else bad "$1" "$out"; fi; }

echo "== unit tests"
unit testrun_test

for mode in ${MBTEST_MODES:-debug release}; do
flag=""
[ $mode = release ] && flag="--release"
echo "== mbuild ($mode)"
sh "$here/tools/mcompile.sh" $flag "$here/src/main.mettle" -o "$S/mbuild-$mode" >"$S/build-$mode.log" 2>&1 || { cat "$S/build-$mode.log"; exit 1; }
MB="$S/mbuild-$mode"
W="$S/$mode"
mkdir -p "$W"

# --- mb_test_glob and mb_test_exclude
proj "$W/globs" <<'EOF2'
  mb_test_glob("examples/*.mettle");
  mb_test_exclude("helper, src/slow.mettle");
EOF2
cd "$W/globs" || exit 1
mkdir -p examples
prog tests/a_test.mettle 0
prog tests/helper_test.mettle 1
prog examples/demo.mettle 0
printf 'export fn lib() -> int32 {\n  return 0;\n}\n' > examples/lib.mettle
printf '@test fn slow() -> int32 {\n  return 1;\n}\n' > src/slow.mettle
mb test
check "globs: an example is a test program" sh -c 'grep -q "demo" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
check "globs: a file without fn main is not" hasnt "lib"
check "exclude: left out of the default set" sh -c '! grep -q "helper\|slow" "$0/last.out"' "$S"
mb test helper
check "exclude: naming one still runs it" sh -c 'grep -q "helper" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
mkdir -p examples/more
prog examples/more/demo.mettle 0
sed -i 's|examples/\*.mettle|examples/**/*.mettle|' mbuild.mettle
mb test
check "globs: two equal stems" has "error: two test programs are named demo: examples/demo.mettle and examples/more/demo.mettle"

# --- the runner: pass, fail, timeout, process groups, repeat, warnings, cache, parallel isolation
proj "$W/run" <<'EOF2'
  mb_test_set("*", "timeout", "20");
  mb_test_set("hang", "timeout", "1");
  mb_test_set("flaky", "repeat", "4");
  mb_test_set("count", "checks", "PASS");
  mb_test_set("warn", "warnings", "error");
  mb_test_set("both", "matrix", "debug, release");
  mb_test_set("solo", "serial", "true");
  mb_test_set("intmp", "cwd", "tmp");
  mb_test_set("nobuild", "run", "false");
  mb_test_cmd("iso1", "sh tests/iso.sh one");
  mb_test_cmd("iso2", "sh tests/iso.sh two");
  mb_test_cmd("solo", "sh tests/solo.sh");
  mb_test_cmd("intmp", "sh -c 'test \"$(pwd)\" = \"$MBUILD_TEST_TMP\" && test -d \"$MBUILD_TEST_OUT\"'");
  mb_test_env("iso1", "WHO=first");
  mb_test_env("*", "ALL=yes");
  mb_on("linux");
  mb_link_libs("c");
  mb_on("");
EOF2
cd "$W/run" || exit 1
printf 'import "std/io";\nfn main() -> int32 {\n  println("PASS a");\n  println("PASS b");\n  println("PASS c");\n  return 0;\n}\n' > tests/count_test.mettle
prog tests/both_test.mettle 0
prog tests/nobuild_test.mettle 1
printf 'import "std/io";\nimport "std/env";\nfn main() -> int32 {\n  var k: string = env_get_or("MBUILD_TEST_RUN", "0");\n  println("run " + k);\n  if (k == "3") {\n    return 1;\n  }\n  return 0;\n}\n' > tests/flaky_test.mettle
printf 'extern fn c_sleep(s: uint32) -> uint32 = "sleep";\nextern fn c_fork() -> int32 = "fork";\nfn main() -> int32 {\n  c_fork();\n  c_sleep(60);\n  return 0;\n}\n' > tests/hang_test.mettle
printf 'fn main() -> int32 {\n  var unused: int32 = 3;\n  return 0;\n}\n' > tests/warn_test.mettle
cat > tests/iso.sh <<'EOF2'
echo "$1" > "$TMPDIR/f"
sleep 0.3
[ "$(cat "$TMPDIR/f")" = "$1" ] || { echo "TMPDIR shared"; exit 1; }
[ "$(pwd)" = "$MBUILD_ROOT" ] || { echo "cwd $(pwd)"; exit 1; }
[ "$ALL" = yes ] || exit 1
[ "$1" = two ] || [ "$WHO" = first ] || exit 1
[ "$MBUILD_TEST_CELL" = linux/debug ] || exit 1
echo "end $MBUILD_TEST_NAME" >> order.log
EOF2
printf 'echo solo >> order.log\n' > tests/solo.sh
mb test -j 4
check "runner: a line per test" sh -c 'grep -q "^test count (debug) ... ok .*  3 checks$" "$0/last.out" && grep -qF "test both (debug, release) ... ok" "$0/last.out" && grep -qF "test iso1 (debug) ... ok" "$0/last.out" && grep -qF "test iso2 (debug) ... ok" "$0/last.out" && grep -qF "test intmp (debug) ... ok" "$0/last.out"' "$S"
check "runner: run=false only builds" sh -c 'grep -qF "test nobuild (debug) ... ok" "$0/last.out" && grep -qF "Compiling test nobuild (linux, debug)" "$0/last.out"' "$S"
check "runner: timeout" line "test hang (debug) ... TIMEOUT 1.0s"
check "runner: the timeout reaches what the test forked" sh -c '! ps -eo args | grep -v grep | grep -q "$0/run/.mbuild/test-bins/linux/debug/hang"' "$W"
check "runner: repeat counts failed runs" line "test flaky (debug) ... FAILED 1/4"
check "runner: the failed run, once" sh -c 'grep -qxF -- "---- flaky (linux/debug, run 3): exit 1" "$0/last.out" && grep -qxF "  run 3" "$0/last.out" && [ -d .mbuild/test-run/linux-debug/flaky/3 ] && [ ! -e .mbuild/test-run/linux-debug/flaky/2 ]' "$S"
check "runner: a denied warning fails without running" sh -c 'grep -qF "test warn (debug) ... FAILED" "$0/last.out" && grep -qF -- "---- warn (linux/debug): warning W0001 at tests/warn_test.mettle:2" "$0/last.out"' "$S"
check "runner: the serial test runs after the rest" sh -c '[ "$(tail -1 order.log)" = solo ] && grep -q "end iso1" order.log && grep -q "end iso2" order.log'
check "runner: summary" sh -c 'grep -q "^test result: FAILED. 7 passed, 3 failed, 3 checks (" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
check "runner: passing runs leave nothing" sh -c '[ ! -e .mbuild/test-run/linux-debug/count ] && [ ! -e .mbuild/test-run/linux-release/both ]'
mb test count both nobuild
check "cache: a hit" sh -c 'grep -qF "test count (debug) ... ok (cached)" "$0/last.out" && grep -qF "test both (debug, release) ... ok (cached)" "$0/last.out" && grep -qF "3 passed, 0 failed, 3 cached" "$0/last.out" && ! grep -q Compiling "$0/last.out"' "$S"
sed -i 's|"count", "checks", "PASS"|"count", "checks", "PASS b"|' mbuild.mettle
mb test count
check "cache: a changed setting runs it again" sh -c 'grep -q "^test count (debug) ... ok .*  1 check$" "$0/last.out" && ! grep -q Compiling "$0/last.out"' "$S"
printf '\n' >> tests/count_test.mettle
mb test count
check "cache: a changed source builds and runs it again" sh -c 'grep -qF "Compiling test count (linux, debug)" "$0/last.out" && ! grep -qF "(cached)" "$0/last.out"' "$S"
mb test count --force
check "cache: --force" sh -c 'grep -qF "Compiling test count" "$0/last.out" && ! grep -qF "(cached)" "$0/last.out"' "$S"
mb test count --repeat=3
check "cache: --repeat is never cached" sh -c '! grep -qF "(cached)" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
mb test count both --matrix=release
check "--matrix=CSV replaces the cells" sh -c 'grep -qF "test count (release) ... ok" "$0/last.out" && grep -qF "test both (release) ... ok" "$0/last.out"' "$S"
mb test -r count
check "-r is --matrix=release" line "test count (release) ... ok (cached)"
mb test --matrix=mars/debug
check "--matrix=CSV is checked" has "error: --matrix=mars/debug: unknown target 'mars'"
mb test -q
check "-q: failures only" sh -c '! grep -q "\.\.\. ok" "$0/last.out" && grep -qF "test hang (debug) ... TIMEOUT" "$0/last.out" && grep -q "^test result: FAILED" "$0/last.out"' "$S"
mb test both --keep --force
check "--keep keeps passing runs" sh -c '[ -f .mbuild/test-run/linux-debug/both/1/stdout ] && [ -d .mbuild/test-run/linux-release/both/1/tmp ] && grep -qx "PASS one" .mbuild/test-run/linux-debug/both/1/stdout'
mb test count --deny-warnings
check "--deny-warnings" code_is 0
mb test warn --deny-warnings
check "--deny-warnings fails a warning" code_is 1
mb test nope
check "an unknown test lists them" has "help: the tests are: both, count, flaky, hang, nobuild, warn, iso1, iso2, solo, intmp; or name an @test file"

# --- @test files natively: what the interpreter skips, native=always and never
proj "$W/native" <<'EOF2'
  mb_test_set("lib/always.mettle", "native", "always");
  mb_test_set("lib/never.mettle", "native", "never");
  mb_on("linux");
  mb_link_libs("c");
  mb_on("");
EOF2
cd "$W/native" || exit 1
mkdir -p lib
printf 'export fn add(a: int32, b: int32) -> int32 {\n  return a + b;\n}\n' > lib/calc.mettle
printf 'hello' > lib/data.txt
printf 'import "calc";\nextern fn c_getpid() -> int32 = "getpid";\nfn data() -> string {\n  return import_str "data.txt";\n}\n@test fn adds() -> int32 {\n  if (add(1, 2) != 3) { return 1; }\n  return 0;\n}\n@test fn pid() -> int32 {\n  if (c_getpid() > 0 && data() == "hello") { return 0; }\n  return 1;\n}\nfn main() -> int32 {\n  return 0;\n}\n' > lib/cc.mettle
printf 'import "calc";\n@test fn adds() -> int32 {\n  if (add(1, 2) != 3) { return 1; }\n  return 0;\n}\n@test fn two() {\n  assert(add(1, 1) == 2);\n}\n@test fn wrong() -> int32 {\n  return add(1, 1);\n}\n' > lib/always.mettle
printf 'extern fn c_getpid() -> int32 = "getpid";\n@test fn pid() -> int32 {\n  if (c_getpid() > 0) { return 0; }\n  return 1;\n}\n' > lib/never.mettle
mb test
check "native: a skipped test runs natively, with fn main, a relative import and import_str" sh -c 'grep -q "^test lib/cc.mettle (debug) ... ok .*  2 checks$" "$0/last.out" && grep -qF "Compiling test lib_cc__mbt (linux, debug)" "$0/last.out"' "$S"
check "native: the copy keeps the original's lines" sh -c '[ "$(sed -n 1p .mbuild/test-native/lib/lib_cc__mbt.mettle)" = "import \"std/io\"; import \"calc\";" ] && [ "$(sed -n 14p .mbuild/test-native/lib/lib_cc__mbt.mettle)" = "fn mbt_orig_main() -> int32 {" ] && [ "$(sed -n 10p .mbuild/test-native/lib/lib_cc__mbt.mettle)" = "$(sed -n 10p lib/cc.mettle)" ]' 
check "native=always: every test natively, a failure named" sh -c 'grep -qF "test lib/always.mettle (debug) ... FAILED" "$0/last.out" && grep -qF -- "---- lib/always.mettle (linux/debug): natively: exit 1" "$0/last.out" && grep -qF "  test two ... ok" "$0/last.out" && grep -qF "  test wrong ... FAILED (returned 2)" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
check "native=never: the interpreter's verdict" sh -c 'grep -qF "test lib/never.mettle (debug) ... ok" "$0/last.out" && ! grep -q "lib_never__mbt" "$0/last.out"' "$S"
mb test lib/cc.mettle
check "native: a passing file is cached, its native run too" line "test lib/cc.mettle (debug) ... ok (cached)"
printf '@test fn more() -> int32 {\n  if (c_getpid() < 0) { return 1; }\n  return 0;\n}\n' >> lib/cc.mettle
mb test lib/cc.mettle --matrix=debug,release
check "native: in every cell" sh -c 'grep -qF "Compiling test lib_cc__mbt (linux, release)" "$0/last.out" && grep -q "^test lib/cc.mettle (debug, release) ... ok" "$0/last.out"' "$S"

done
echo "test_runner: $pass passed, $failed failed"
[ $failed = 0 ]
