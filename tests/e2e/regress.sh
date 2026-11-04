#!/bin/sh
# regress.sh: regressions without a feature suite of their own.
#   METTLE=dev-compiler sh tests/e2e/regress.sh [SUITE...]   (scratch: $MBTEST_TMP)
# 1. views into a temporary `a + b` argument (DESIGN.md 2, issue 6) stay valid;
# 2. the CLI checks below, debug and --release;
# 3. each SUITE (default deps) passes when run from an empty directory and leaves
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
check() { name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$T/last.out" 2>/dev/null)"; fi; }
has() { grep -qF -- "$1" "$T/last.out"; }
hasnt() { ! grep -qF -- "$1" "$T/last.out"; }
code_is() { [ "$(cat "$T/last.code")" = "$1" ]; }
mb() { "$MB" "$@" >"$T/last.out" 2>&1; echo $? >"$T/last.code"; }
# proj DIR, then lines of fn project() on stdin
proj() {
  rm -rf "$1"; mkdir -p "$1/src"
  { printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("%s", "v0.1.0");\n' "$(basename "$1")"; sed 's/^/  /'; printf '}\n'; } >"$1/mbuild.mettle"
  printf 'fn main() -> int32 { return 0; }\n' >"$1/src/main.mettle"
}

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

export LC_ALL=C NO_COLOR=1 MBUILD_METTLE_LINUX="$METTLE"
unset MBUILD_COLOR MBUILD_DEPTH MBUILD_CHAIN
sh "$here/tests/fixtures/make-registry.sh" "$T/fx" >/dev/null || exit 1
export MBUILD_REGISTRY="$T/fx/registry"
for mode in debug release; do
flag=""; [ $mode = release ] && flag=--release
echo "== mbuild ($mode)"
if ! "$METTLE" --build $flag "$here/src/main.mettle" -o "$T/mbuild-$mode" >"$T/build-$mode.log" 2>&1; then
  bad "mbuild builds ($mode)" "$(cat "$T/build-$mode.log")"; continue
fi
MB="$T/mbuild-$mode"
W="$T/$mode"
export MBUILD_HOME="$W/home"

P="$W/partial"
proj "$P" </dev/null
cd "$P" || exit 1
mb get strutil@v2
check "$mode: a partial version skips pre-releases" has "error: strutil has no stable version v2 (required by the command line); its pre-releases: v2.0.0-rc.1"
check "$mode: ... and names the full version" has "help: a pre-release is selected only by its full version, e.g. strutil@v2.0.0-rc.1"
mb get strutil@v1
check "$mode: a partial version takes the newest stable" grep -qF 'mb_dep("strutil", "v1.1.0");' mbuild.mettle

P="$W/cmdout"
proj "$P" </dev/null
cat >>"$P/mbuild.mettle" <<'MEOF'

fn cmd_out(a: MbArgs*) -> int32 {
  var c: MbCmd* = mb_cmd("printf");
  mb_cmd_arg(c, "one\\ntwo\\n\\n");
  mb_say("[" + mb_cmd_output(c) + "]");
  return 0;
}
MEOF
cd "$P" || exit 1
mb out
check "$mode: mb_cmd_output drops one trailing newline" sh -c 'printf "[one\ntwo\n]\n" | cmp -s - "$0"' "$T/last.out"
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
