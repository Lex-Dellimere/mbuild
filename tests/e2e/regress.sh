#!/bin/sh
# regress.sh: regressions without a feature suite of their own.
#   METTLE=dev-compiler sh tests/e2e/regress.sh [SUITE...]   (scratch: $MBTEST_TMP)
# 1. views into a temporary `a + b` argument (DESIGN.md 2, issue 6) stay valid;
# 2. each SUITE (default deps) passes when run from an empty directory and leaves
#    nothing in it (a dangling view once had mbuild vendor mkdir garbage names there).

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
export METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
T="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/regress}"
rm -rf "$T"
mkdir -p "$T"

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -30; }

echo "== views into temporaries"
cat >"$T/views.mettle" <<MEOF
import "std/io";
import "std/mem";
import "$here/src/core/base";
import "$here/src/core/path";

fn tail() -> string { return "rel/file.mettle"; }

fn main() -> int32 {
  // each junk string has its view's source length, so it reuses a freed block
  var d: string = p_dir("/to/vendor/x7/" + tail());
  var j1: string = "##############" + tail();
  var b: string = p_base("/to/" + tail());
  var j2: string = "####" + tail();
  var t: string = s_trim("  " + tail() + "  ");
  var j3: string = "##" + tail() + "##";
  var l: StrList* = s_split("a/" + tail(), 47);
  var j4: string = "##" + tail();
  println("{d}|{b}|{t}|{sl_join(l, ",")}|{slen(j1) + slen(j2) + slen(j3) + slen(j4)}");
  return 0;
}
MEOF
want="/to/vendor/x7/rel|file.mettle|rel/file.mettle|a,rel,file.mettle|84"
for mode in debug release; do
  flag=""; [ $mode = release ] && flag=--release
  if out=$("$METTLE" --build $flag "$T/views.mettle" -o "$T/views-$mode" 2>&1) && got=$("$T/views-$mode" 2>&1); then
    [ "$got" = "$want" ] && ok "views into temporaries ($mode)" || bad "views into temporaries ($mode)" "got  $got
want $want"
  else
    bad "views program builds ($mode)" "$out"
  fi
done

for suite in ${*:-deps}; do
  echo "== $suite from an empty directory"
  cwd="$T/cwd-$suite"
  mkdir -p "$cwd"
  out=$(cd "$cwd" && MBTEST_TMP="$T/$suite" sh "$here/tests/e2e/$suite.sh" 2>&1); rc=$?
  [ $rc = 0 ] && ! printf '%s\n' "$out" | grep -q '^FAIL' && ok "$suite passes" || bad "$suite passes" "$(printf '%s\n' "$out" | grep -A5 '^FAIL')"
  left=$(cd "$cwd" && LC_ALL=C find . -mindepth 1 | cat -v)
  [ -z "$left" ] && ok "$suite leaves its cwd empty" || bad "$suite leaves its cwd empty" "$left"
done

echo "regress: $pass passed, $failed failed"
[ $failed = 0 ]
