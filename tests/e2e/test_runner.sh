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
unit() { u="$1"; shift; if out=$(METTLE="$METTLE" TMPDIR="$S" sh "$here/tools/mcheck.sh" "$here/tests/unit/$u.mettle" --run "$@" 2>&1); then ok "$u ($(printf '%s\n' "$out" | sed -n 's/^\[run\] ok (.*: \(.*\))$/\1/p'))"; else bad "$u" "$out"; fi; }

echo "== unit tests"
unit testrun_test
unit png_test -- "$here/tests/fixtures/png" "$S"

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
check "runner: the table: - for a cell a test isn't in" sh -c 'grep -qE "^test +linux/debug +linux/release$" "$0/last.out" && grep -qE "^both +ok +ok$" "$0/last.out" && grep -qE "^iso1 +ok +-$" "$0/last.out"' "$S"
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

# --- fixtures: mb_service per run, ports from the pool
mkdir -p "$W/fix/src" "$W/fix/tools"
cp "$here/tests/fixtures/svc_app.mettle" "$W/fix/src/main.mettle"
cp "$here/tests/fixtures/svc_srv.mettle" "$W/fix/tools/srv.mettle"
cat > "$W/fix/mbuild.mettle" <<'EOF2'
import "mbuild/api";

fn project() {
  mb_package("fix", "0.1.0");
  mb_bin("app", "src/main.mettle");
  mb_bin("srv", "tools/srv.mettle");
  mb_service("db", "srv $MBUILD_PORT_DB db.pid 100");
  mb_service_port("db", 0);
  mb_service("note", "sh -c 'echo $MBUILD_PORT_DB > port.txt; sleep 30'");
  mb_test_cmd("live1", "app $MBUILD_PORT_DB 0");
  mb_test_cmd("live2", "sh -c 'test -n \"$MBUILD_PORT_DB\" && exec \"$0\" \"$MBUILD_PORT_DB\" 0' build/linux/debug/app");
  mb_test_cmd("slow", "sleep 30");
  mb_test_set("live1", "services", "db");
  mb_test_set("live2", "services", "db");
  mb_test_set("slow", "services", "db");
  mb_test_set("slow", "timeout", "1");
}
EOF2
cd "$W/fix" || exit 1
mb test live1 live2 slow -j 4
check "fixtures: two tests at once, each with its db" sh -c 'grep -qF "test live1 (debug) ... ok" "$0/last.out" && grep -qF "test live2 (debug) ... ok" "$0/last.out"' "$S"
p1=$(sed -n 's/^srv \([0-9]*\): listening$/\1/p' .mbuild/test-run/linux-debug/slow/1/service-db.log)
check "fixtures: the test's timeout stops its fixture" sh -c 'grep -qF "test slow (debug) ... TIMEOUT 1.0s" "$0/last.out" && [ -s .mbuild/test-run/linux-debug/slow/1/tmp/db.pid ] && ! kill -0 "$(cat .mbuild/test-run/linux-debug/slow/1/tmp/db.pid)" 2>/dev/null' "$S"
check "fixtures: ports come from the pool, and go back" sh -c '[ "${0:-0}" -ge 20000 ] && [ "$0" -le 29999 ] && [ -z "$(ls "$1/home/tmp/ports")" ]' "$p1" "$S"
# a stale lock is taken over; a live one is skipped
P=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])' 2>/dev/null || echo 24567)
mkdir -p "$S/home/tmp/ports/$P"
echo 999999 > "$S/home/tmp/ports/$P/pid"
sed -i "s|  mb_test_set(\"live1\", \"services\", \"db\");|&\n  mb_test_set(\"*\", \"ports\", \"$P-$P\");|" mbuild.mettle
mb test live1 --keep
check "ports: a stale lock is taken over" sh -c 'grep -qF "test live1 (debug) ... ok" "$0/last.out" && grep -qxF "srv $1: listening" .mbuild/test-run/linux-debug/live1/1/service-db.log' "$S" "$P"
mkdir -p "$S/home/tmp/ports/$P"
echo $$ > "$S/home/tmp/ports/$P/pid"
mb test live1
check "ports: a held one is not taken" sh -c 'grep -qF "error: service db: no free port in $1-$1" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S" "$P"
rm -rf "$S/home/tmp/ports/$P"
sed -i "/\"ports\"/d" mbuild.mettle
sed -i 's|srv $MBUILD_PORT_DB db.pid 100|srv $MBUILD_PORT_DB db.pid 0 quiet|; s|  mb_service_port("db", 0);|&\n  mb_service_wait("db", 300);|' mbuild.mettle
mb test live1
check "fixtures: a service that does not come up fails the run, with its log" sh -c 'grep -q -- "^---- live1 (linux/debug): service db: port [0-9]* not open after 0.3s$" "$0/last.out" && grep -q "^  srv [0-9]*: not listening$" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
sed -i 's|srv $MBUILD_PORT_DB db.pid 0 quiet|srv $MBUILD_PORT_DB db.pid 100|' mbuild.mettle
mb run app -- 1 0 500
check "run: port 0 takes one from the pool, \$MBUILD_PORT_DB names it" sh -c 'port=$(sed -n "s/^ *Ready db on :\([0-9]*\) .*/\1/p" "$0/last.out"); [ -n "$port" ] && grep -qF "Starting note (sh -c '"'"'echo $port > " "$0/last.out" && [ -z "$(ls "$0/home/tmp/ports")" ]' "$S"

# --- golden files: compare, bless, cross-cell
proj "$W/gold" <<'EOF2'
  mb_test_cmd("gen", "sh tests/gen.sh");
  mb_test_cmd("say", "sh -c 'echo hello; echo $MBUILD_TEST_CELL > $MBUILD_TEST_OUT/cell.txt'");
  mb_test_set("say", "golden", "files,stdout");
  mb_test_set("say", "matrix", "debug, release");
  mb_test_set("say", "golden-cross", "false");
  mb_test_cmd("both", "sh tests/both.sh");
  mb_test_set("both", "matrix", "debug, release");
EOF2
cd "$W/gold" || exit 1
cat > tests/gen.sh <<'EOF2'
printf 'line 1\nline 2\nline 3\n' > "$MBUILD_TEST_OUT/a.txt"
mkdir -p "$MBUILD_TEST_OUT/sub"
printf 'x\000y' > "$MBUILD_TEST_OUT/sub/b.bin"
EOF2
printf 'echo same > "$MBUILD_TEST_OUT/x.txt"\n' > tests/both.sh
mb test gen say --bless
check "bless: writes the first cell's outputs" sh -c 'grep -qxF "    Blessing tests/golden/gen/a.txt" "$0/last.out" && grep -qxF "    Blessing tests/golden/gen/sub/b.bin" "$0/last.out" && grep -qxF "    Blessing tests/golden/say/stdout" "$0/last.out" && [ "$(cat tests/golden/say/cell.txt)" = linux/debug ] && [ "$(cat tests/golden/say/stdout)" = hello ] && [ "$(cat "$0/last.code")" = 0 ]' "$S"
mb test gen say
check "golden: a match" sh -c 'grep -qF "test gen (debug) ... ok" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
check "golden: each cell against it" has "---- say (linux/release): golden out/cell.txt differs at line 1"
sed -i 's/line 2/line two/' tests/gen.sh
mb test gen
check "golden: a text mismatch names the line" sh -c 'grep -qxF -- "---- gen (linux/debug): golden out/a.txt differs at line 2" "$0/last.out" && grep -qxF "  expected: line 2" "$0/last.out" && grep -qxF "  written:  line two" "$0/last.out"' "$S"
sed -i 's/line two/line 2/; s/x\\000y/x\\000z/' tests/gen.sh
mb test gen
check "golden: a binary mismatch names the byte" has "---- gen (linux/debug): golden out/sub/b.bin differs at byte 2 (3 bytes expected, 3 written)"
sed -i 's/x\\000z/x\\000y/' tests/gen.sh
echo extra >> tests/gen.sh
printf 'echo extra > "$MBUILD_TEST_OUT/extra.txt"\n' >> tests/gen.sh
mb test gen
check "golden: an extra output" has "---- gen (linux/debug): out/extra.txt has no golden file (tests/golden/gen/extra.txt; mbuild test --bless writes it)"
sed -i '/extra/d; /sub/d' tests/gen.sh
mb test gen
check "golden: a missing output" has "---- gen (linux/debug): golden tests/golden/gen/sub/b.bin: out/sub/b.bin was not written"
mb test gen --bless --only a.txt
check "bless --only: other paths left alone" sh -c '[ -f tests/golden/gen/sub/b.bin ] && ! grep -q Blessing "$0/last.out"' "$S"
mb test gen --bless
check "bless: removes what is no longer written" sh -c 'grep -qxF "    Removing tests/golden/gen/sub/b.bin" "$0/last.out" && [ ! -e tests/golden/gen/sub/b.bin ]' "$S"
printf 'echo $MBUILD_TEST_CELL > "$MBUILD_TEST_OUT/x.txt"\n' > tests/both.sh
mb test both
check "golden-cross: cells must agree" sh -c 'grep -qF "test both (debug, release) ... FAILED" "$0/last.out" && grep -qF -- "---- both (linux/release): not as in linux/debug: out/x.txt differs at line 1" "$0/last.out"' "$S"
sed -i 's/^printf.*with_stdout.*//' tests/both.sh
printf 'echo same > "$MBUILD_TEST_OUT/x.txt"\n' > tests/both.sh
mb test both
check "golden-cross: agreeing cells pass" line "test both (debug, release) ... ok  0.0s"
mb test gen --only x
check "--only needs --bless" has "error: --only goes with --bless"
cp "$here/tests/fixtures/png/rgba8.png" tests/img.png
sed -i 's|  mb_test_cmd("both", "sh tests/both.sh");|&\n  mb_test_cmd("img", "cp tests/img.png $MBUILD_TEST_OUT/plot.png");|' mbuild.mettle
mb test img --bless
cp "$here/tests/fixtures/png/rgba8_stored.png" tests/img.png
mb test img
check "png: other bytes, the same pixels" line "test img (debug) ... ok  0.0s"
cp "$here/tests/fixtures/png/rgba8_near.png" tests/img.png
mb test img
check "png: pixels that differ, and a diff image" sh -c 'grep -qxF -- "---- img (linux/debug): golden out/plot.png differs: 3 of 128 pixels beyond 0 (at most 0), channels off by up to 48" "$0/last.out" && [ -s .mbuild/test-run/linux-debug/img/1/out/plot.diff.png ]' "$S"
sed -i 's|  mb_test_cmd("img", |  mb_test_set("img", "png-tolerance", "3,0.01,48");\n&|' mbuild.mettle
mb test img
check "png: within png-tolerance" line "test img (debug) ... ok  0.0s"

# --- {image:NAME} in a command test: built on demand, once per cell of the program
proj "$W/image" <<'EOF2'
  mb_test_bin("hello", "tests/hello.mettle");
  mb_test_set("hello", "matrix", "debug, release");
  mb_test_cmd("show", "sh tests/show.sh {{image:hello} {{elf:hello}");
  mb_test_cmd("own", "sh tests/show.sh {{image:hello}");
  mb_test_set("own", "matrix", "release");
  mb_test_cmd("nope", "sh tests/show.sh {{image:ghost}");
EOF2
cd "$W/image" || exit 1
prog tests/hello.mettle 0
printf 'echo "$1"\ntest -x "$1" || exit 1\n"$1" || exit 1\n' > tests/show.sh
mb test show --keep
check "image: the command test builds the program" sh -c 'grep -qF "Compiling test hello (linux, debug)" "$0/last.out" && grep -qF "Compiling test hello (linux, release)" "$0/last.out" && [ -x .mbuild/test-bins/linux/debug/hello ] && [ -x .mbuild/test-bins/linux/release/hello ]' "$S"
check "image: one run per cell of the program" sh -c 'grep -qF "test show (debug, release) ... ok" "$0/last.out" && grep -qF "hello" .mbuild/test-run/linux-release/show/1/stdout' "$S"
check "image: the cell's absolute path" sh -c 'grep -qxF "$1/.mbuild/test-bins/linux/debug/hello" .mbuild/test-run/linux-debug/show/1/stdout && grep -qxF "$1/.mbuild/test-bins/linux/release/hello" .mbuild/test-run/linux-release/show/1/stdout' "$S" "$W/image"
mb test own
check "image: the test's own matrix wins" line "test own (release) ... ok  0.0s"
mb test nope
check "image: a name that is no test program" has "---- nope (linux/debug): no test program \`ghost\` for {image:ghost}"
mb test hello show
check "image: the program and its command test" sh -c 'grep -qF "test hello (debug, release) ... ok" "$0/last.out" && grep -qF "test show (debug, release) ... ok" "$0/last.out"' "$S"

done
echo "test_runner: $pass passed, $failed failed"
[ $failed = 0 ]
