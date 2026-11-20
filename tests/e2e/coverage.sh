#!/bin/sh
# coverage.sh: `mbuild test --coverage` end to end (hit and missed functions and lines, merging across programs and repeats, exit(), coverage-min, the text and HTML reports), mbuild built debug and --release.
#   METTLE=dev-compiler sh tests/e2e/coverage.sh   (scratch: $MBTEST_TMP)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
S="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/coverage}"
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

unit() { u="$1"; shift; if out=$(METTLE="$METTLE" TMPDIR="$S" sh "$here/tools/mcheck.sh" "$here/tests/unit/$u.mettle" --run "$@" 2>&1); then ok "$u ($(printf '%s\n' "$out" | sed -n 's/^\[run\] ok (.*: \(.*\))$/\1/p'))"; else bad "$u" "$out"; fi; }

echo "== unit tests"
unit cover_test

# fixture: a library with one function no test calls, two test programs
# (one repeated), an @test file, a command test running a bin, a program
# ending through exit(), a path dependency
fixture() {
  mkdir -p "$1/src" "$1/tests" "$1/vendor/bare"
  cat > "$1/mbuild.mettle" <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("cov", "0.1.0");
  mb_bin("covbin", "src/main.mettle");
  mb_test_set("loop", "repeat", "3");
  mb_test_cmd("cli", "covbin");
}

fn deps() {
  mb_dep_path("bare", "vendor/bare");
}
EOF
  cat > "$1/src/calc.mettle" <<'EOF'
// calc: the library under test.

export fn add(a: int64, b: int64) -> int64 {
  return a + b;
}

export fn clamp(x: int64, hi: int64) -> int64 {
  if (x > hi) {
    return hi;
  }
  return x;
}

export fn twice(x: int64) -> int64 {
  return x * 2;
}

export fn untested(x: int64) -> int64 {
  var y: int64 = x;
  return y - 1;
}

export fn at_exit_only(x: int64) -> int64 {
  return x + 7;
}

@test fn inline_check() -> int32 {
  return 0;
}
EOF
  printf 'import "calc";\n\nfn main() -> int32 {\n  if (twice(2) != 4) {\n    return 1;\n  }\n  return 0;\n}\n' > "$1/src/main.mettle"
  printf 'export fn bare_x() -> int64 {\n  return 2;\n}\n' > "$1/vendor/bare/bare.mettle"
  printf 'import "std/io";\nimport "../src/calc";\nimport "bare/bare";\n\nfn main() -> int32 {\n  if (add(2, 3) != 5 || bare_x() != 2) {\n    return 1;\n  }\n  println("PASS add");\n  return 0;\n}\n' > "$1/tests/add_test.mettle"
  printf 'import "std/io";\nimport "../src/calc";\n\nfn main() -> int32 {\n  if (clamp(50, 10) != 10) {\n    return 1;\n  }\n  return 0;\n}\n' > "$1/tests/loop_test.mettle"
  printf 'import "std/process";\nimport "../src/calc";\n\nfn main() -> int32 {\n  if (at_exit_only(1) != 8) {\n    return 1;\n  }\n  exit(0);\n  return 0;\n}\n' > "$1/tests/quit_test.mettle"
  printf 'import "../src/calc";\n\n@test fn doubles() -> int32 {\n  if (twice(4) != 8) {\n    return 1;\n  }\n  return 0;\n}\n' > "$1/tests/twice.mettle"
}

for mode in ${MBTEST_MODES:-debug release}; do
flag=""
[ $mode = release ] && flag="--release"
echo "== mbuild ($mode)"
sh "$here/tools/mcompile.sh" $flag "$here/src/main.mettle" -o "$S/mbuild-$mode" >"$S/build-$mode.log" 2>&1 || { cat "$S/build-$mode.log"; exit 1; }
MB="$S/mbuild-$mode"
W="$S/$mode"
fixture "$W/cov"
cd "$W/cov" || exit 1

mb test --coverage
check "$mode: the tests pass" eval 'code_is 0 && has "test result: ok. 6 passed, 0 failed"'
check "$mode: no annotated listing or optimizer report in the output" eval 'hasnt "Mettle codegen annotation" && hasnt "optimization report" && hasnt "Runtime profile"'
check "$mode: profiles of every run merged (1 + 3 repeats + two @test files + command)" has "coverage (7 profiles merged):"
check "$mode: the table" eval 'line "file             functions          lines (approximate)" && line "src/calc.mettle  3/5        60.0%   4/7        57.1%" && line "src/main.mettle  1/1       100.0%   3/3       100.0%" && line "total            4/6        66.6%   7/10       70.0%"'
check "$mode: two test programs merge (add and clamp both hit)" eval 'hasnt "calc.mettle:3 add" && hasnt "calc.mettle:7 clamp"'
check "$mode: the uncovered functions with file:line" eval 'line "uncovered functions:" && line "  src/calc.mettle:18 untested" && line "  src/calc.mettle:23 at_exit_only"'
check "$mode: exit() writes no profile" has "note: no coverage from quit: it wrote no profile (a program ending through exit(), a signal or a timeout writes none)"
check "$mode: tests, @test functions and dependencies left out" eval '! grep -q "^tests/\\|^vendor/" "$S/last.out" && hasnt "inline_check" && hasnt "bare"'
check "$mode: built apart from build/" sh -c '[ ! -e build/linux ] && [ -x .mbuild/coverage/linux/debug/test/loop ] && [ -x .mbuild/coverage/linux/debug/bin/covbin ]'
check "$mode: no report files without --coverage-out" sh -c '[ ! -e build/coverage ]'

mb test --coverage=text
check "$mode: =text writes the annotated files" eval 'code_is 0 && has "Wrote build/coverage/index.txt"'
check "$mode: text: per-line markers" sh -c 'f=build/coverage/src/calc.mettle.txt; grep -qxF "src/calc.mettle: functions 3/5, lines 4/7" $f && grep -qxF "    7 F+ | export fn clamp(x: int64, hi: int64) -> int64 {" $f && grep -qxF "    9 +  |     return hi;" $f && grep -qxF "   11 -  |   return x;" $f && grep -qxF "   18 F- | export fn untested(x: int64) -> int64 {" $f && grep -qxF "    1    | // calc: the library under test." $f'
check "$mode: text: the index is the table" sh -c 'grep -qxF "  src/calc.mettle:18 untested" build/coverage/index.txt'

mb test --coverage=html --coverage-out "$S/html-$mode"
check "$mode: html into --coverage-out" sh -c 'grep -qF "<a href=\"src/calc.mettle.html\">src/calc.mettle</a>" "$0/index.html" && grep -qF "<span class=\"m f\">   18 F- export fn untested(x: int64) -&gt; int64 {" "$0/src/calc.mettle.html" && grep -qF "<a href=\"../index.html\">" "$0/src/main.mettle.html"' "$S/html-$mode"
check "$mode: html replaces nothing in build/coverage" sh -c '[ -e build/coverage/index.txt ] && [ ! -e build/coverage/index.html ]'

sed -i 's|  mb_test_cmd("cli", "covbin");|  mb_test_cmd("cli", "covbin");\n  mb_test_set("*", "coverage-min", "80");|' mbuild.mettle
mb test --coverage
check "$mode: coverage-min fails the run" eval 'code_is 1 && has "error: 66.6% of functions covered, under coverage-min 80%" && has "test result: FAILED. 6 passed, 0 failed, 2 checks, coverage under coverage-min"'
mb test
check "$mode: coverage-min only applies with --coverage" eval 'code_is 0'
sed -i 's|"coverage-min", "80"|"coverage-min", "60"|' mbuild.mettle
mb test --coverage
check "$mode: coverage-min holds" eval 'code_is 0 && hasnt "under coverage-min"'
sed -i 's|mb_test_set("\*", "coverage-min", "60")|mb_test_set("loop", "coverage-min", "60")|' mbuild.mettle
mb test
check "$mode: coverage-min is for every test" eval 'code_is 1 && has "coverage-min is set for every test"'
sed -i 's|mb_test_set("loop", "coverage-min", "60")|mb_test_set("*", "coverage-min", "1o")|' mbuild.mettle
mb test
check "$mode: coverage-min is a percent" eval 'code_is 1 && has "coverage-min is a percent of functions from 0 to 100"'
sed -i '/coverage-min/d' mbuild.mettle

mb test --coverage=xml
check "$mode: --coverage=xml refused" eval 'code_is 1 && has "--coverage takes text or html, not \`xml\`"'
mb help test
check "$mode: help test names --coverage" eval 'has "--coverage[=text|html]" && has "coverage-min"'
cd "$S" || exit 1
done

echo
echo "coverage: $pass passed, $failed failed"
[ $failed -eq 0 ]
