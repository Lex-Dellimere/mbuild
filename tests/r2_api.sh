#!/bin/sh
# r2_api.sh: acceptance tests of src/api.mettle (DESIGN.md 12.21 Group S, S-3)
# through tests/api_driver.mettle, built with all three compilers (head,
# v0.17.0 Linux, v0.17.0 Windows under wine) and run with each.
#
#   sh tests/r2_api.sh
#   SKIP_WINE=1 sh tests/r2_api.sh     Linux drivers only
#
# Scratch: /tmp/opencode/r2-S. Checkouts of apilib are made with git archive
# from the round-2 fixtures (tests/fixtures/make-fixtures-r2.sh).

set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
S=/tmp/opencode/r2-S
OUT=/tmp/opencode/mcheck
export WINEDEBUG=-all
rm -rf "$S"
mkdir -p "$S"

pass=0
failn=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /'; }
# expect NAME OUTPUT WANT: OUTPUT holds the line WANT exactly.
expect_line() {
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else bad "$1 (wanted line: $3)" "$2"; fi
}
expect_no() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then bad "$1 (unwanted: $3)" "$2"; else ok "$1"; fi
}
expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got:
$2
want:
$3"; fi
}

echo "== building the driver"
built=$("$here/tools/mcheck.sh" "$here/tests/api_driver.mettle") || { printf '%s\n' "$built"; echo "driver build failed"; exit 1; }
printf '%s\n' "$built"
if grep -q "warning" "$OUT"/api_driver.head.log "$OUT"/api_driver.headrel.log "$OUT"/api_driver.l017.log "$OUT"/api_driver.w017.log; then
  bad "driver compiles without warnings"
else
  ok "driver compiles without warnings in all four variants"
fi

echo "== fixtures"
F="$S/fx"
"$here/tests/fixtures/make-fixtures.sh" "$F" >/dev/null || exit 1
"$here/tests/fixtures/make-fixtures-r2.sh" "$F" >/dev/null || exit 1
R="$F/gitbase/github.com/demo/apilib"
for v in v1.0.0 v1.1.0 v1.2.0 v2.0.0; do
  mkdir -p "$S/$v"
  git -C "$R" archive "$v" | tar -x -C "$S/$v"
done

# A package with files that are not part of its API.
P="$S/filters"
mkdir -p "$P/sub" "$P/tests" "$P/examples" "$P/cmd/tool" "$P/.hidden" "$P/inner/tests"
printf 'export fn f_top() -> int32 { return 1; }\n' > "$P/top.mettle"
printf '// a comment\nexport struct FSub { x: int64; }\n' > "$P/sub/sub.mettle"
printf 'export fn f_inner_tests() -> int32 { return 1; }\n' > "$P/inner/tests/kept.mettle"
printf 'export fn no_a() -> int32 { return 1; }\n' > "$P/tests/a.mettle"
printf 'export fn no_b() -> int32 { return 1; }\n' > "$P/examples/b.mettle"
printf 'export fn no_c() -> int32 { return 1; }\n' > "$P/cmd/tool/main.mettle"
printf 'export fn no_d() -> int32 { return 1; }\n' > "$P/.hidden/d.mettle"
printf 'export fn no_e() -> int32 { return 1; }\n' > "$P/top_test.mettle"
printf 'export fn no_f() -> int32 { return 1; }\n' > "$P/test_top.mettle"
printf 'export fn no_g() -> int32 { return 1; }\n' > "$P/notes.txt"

USE='al_mul src/main.mettle:5'
REMOVED='    removed  fn al_mul(a: int32, b: int32) -> int32       used at src/main.mettle:5'
CHANGED_OLD='    changed  fn al_add(a: int32, b: int32) -> int32'
CHANGED_NEW='          -> fn al_add(a: int32, b: int32, c: int32) -> int32   used at src/main.mettle:4'

run_suite() { # label, driver command...
  L="$1"; shift
  echo "== $L"
  out=$("$@" surface "$S/v1.0.0" 2>&1)
  expect_eq "$L: surface of v1.0.0" "$out" "struct AlPair apilib.mettle:1|struct AlPair { a: int32; b: int32 }
fn al_add apilib.mettle:2|fn al_add(a: int32, b: int32) -> int32
fn al_mul apilib.mettle:3|fn al_mul(a: int32, b: int32) -> int32"

  out=$("$@" diff "$S/v1.0.0" "$S/v1.2.0" "$USE" 2>&1)
  expect_line "$L: v1.0.0 -> v1.2.0 removes al_mul" "$out" "removed al_mul"
  expect_line "$L: v1.0.0 -> v1.2.0 changes al_add" "$out" "changed al_add"
  expect_no "$L: v1.0.0 -> v1.2.0 nothing for AlPair" "$out" "AlPair"
  expect_line "$L: removed line of 12.13 exactly" "$out" "$REMOVED"
  expect_line "$L: changed old line" "$out" "$CHANGED_OLD"

  out=$("$@" breaking "$S/v1.0.0" "$S/v1.2.0" "$USE" "al_add src/main.mettle:4" 2>&1)
  expect_eq "$L: breaking report = the 12.13 block" "$out" "removed al_mul
changed al_add
--
$REMOVED
$CHANGED_OLD
$CHANGED_NEW"

  out=$("$@" diff "$S/v1.0.0" "$S/v1.1.0" "$USE" 2>&1)
  expect_eq "$L: v1.0.0 -> v1.1.0 adds al_sub only" "$out" "added al_sub
--
    added    fn al_sub(a: int32, b: int32) -> int32"

  out=$("$@" diff "$S/v1.1.0" "$S/v1.1.0" 2>&1)
  expect_eq "$L: same version, no changes" "$out" "--"

  out=$("$@" diff "$S/v1.2.0" "$S/v2.0.0" "al_sub a.mettle:1" "al_sub b.mettle:2" "al_sub c.mettle:3" "al_sub d.mettle:4" "al_sub a.mettle:1" 2>&1)
  expect_line "$L: many uses abbreviated" "$out" "    removed  fn al_sub(a: int32, b: int32) -> int32       used at a.mettle:1, b.mettle:2, c.mettle:3 and 1 more"
  expect_line "$L: v2 struct removed" "$out" "    removed  struct AlPair { a: int32; b: int32 }"

  out=$("$@" surface "$P" 2>&1)
  expect_eq "$L: file filters" "$out" "fn f_inner_tests inner/tests/kept.mettle:1|fn f_inner_tests() -> int32
struct FSub sub/sub.mettle:2|struct FSub { x: int64 }
fn f_top top.mettle:1|fn f_top() -> int32"
}

run_suite head "$OUT/api_driver.head"
run_suite l017 "$OUT/api_driver.l017"
if [ "${SKIP_WINE:-0}" != 1 ]; then
  run_suite w017 wine "$OUT/api_driver.exe"
fi

echo
echo "r2_api: $pass passed, $failn failed"
[ "$failn" = 0 ]
