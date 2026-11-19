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

done
echo "test_runner: $pass passed, $failed failed"
[ $failed = 0 ]
