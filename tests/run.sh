#!/bin/sh
# run.sh: every test: mcheck of mbuild and the unit drivers, then each tests/e2e suite; one line per suite.
#   METTLE=dev-compiler sh tests/run.sh [SUITE...]   (SKIP_WINE=1 skips wine; logs in $MBTEST_TMP/logs)

set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
export METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
base="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}}"
logs="$base/logs"
rm -rf "$logs"
mkdir -p "$logs"
[ "${SKIP_WINE:-0}" = 1 ] && unset METTLE_WIN
export SKIP_WINE="${SKIP_WINE:-0}"

failed=0
# line NAME CODE LOG SECONDS: the suite's summary line, or its last line
line() {
  sum=$(grep -E '[0-9]+ passed, [0-9]+ failed' "$3" | tail -1 | sed 's/^.*: //')
  [ -n "$sum" ] || sum=$(tail -1 "$3")
  if [ "$2" = 0 ]; then
    printf 'ok    %-11s %s (%ss)\n' "$1" "$sum" "$4"
  else
    printf 'FAIL  %-11s %s (%ss; %s)\n' "$1" "$sum" "$4" "$3"
    failed=$((failed + 1))
  fi
}

start=$(date +%s)
# mbuild, mbuild-shell and every unit driver, each mode built once for all suites (tools/mcompile.sh)
export MBTEST_PREBUILT="$base/prebuilt"
rm -rf "$MBTEST_PREBUILT"
mkdir -p "$MBTEST_PREBUILT"
realpath "$METTLE" >"$MBTEST_PREBUILT/compiler"
jobs=$(($(nproc 2>/dev/null || echo 4) / 2)); [ $jobs -ge 2 ] || jobs=2
( cd "$here" && for e in src/main.mettle cmd/mbuild-shell/main.mettle tests/unit/*_test.mettle; do
    for m in ${MBTEST_MODES:-debug release}; do echo "$e $m"; done
  done ) | xargs -P $jobs -n 2 sh -c 'k=$(printf %s "${2%.mettle}" | sed "s|/|_|g"); o="$MBTEST_PREBUILT/$k.$3"
    if [ $3 = release ]; then "$METTLE" --build --release "$1/$2" -o "$o"; else "$METTLE" --build "$1/$2" -o "$o"; fi >"$o.log" 2>&1 || rm -f "$o"' _ "$here"
{ TMPDIR="$base" sh "$here/tools/mcheck.sh" "$here/src/main.mettle" --run && TMPDIR="$base" sh "$here/tools/mcheck.sh" --all-drivers; } >"$logs/mcheck.log" 2>&1
code=$?
n=$(grep -c '^== ' "$logs/mcheck.log")
echo "$n entries, $(grep -c '^\[\(debug\|release\|windows\)\] \(FAILED\|[0-9]* warnings\)' "$logs/mcheck.log") failed builds" >>"$logs/mcheck.log"
line mcheck $code "$logs/mcheck.log" $(($(date +%s) - start))

suites="${*:-build config registry mreg deps api components init native toolchain platform services shell live}"
for s in $suites; do
  start=$(date +%s)
  # from an empty directory, which must stay empty (a dangling view once made garbage dirs)
  cwd="$base/cwd-$s"
  rm -rf "$cwd"
  mkdir -p "$cwd"
  ( cd "$cwd" && MBTEST_TMP="$base/$s" sh "$here/tests/e2e/$s.sh" ) >"$logs/$s.log" 2>&1
  code=$?
  left=$(cd "$cwd" && LC_ALL=C find . -mindepth 1 | cat -v)
  [ -z "$left" ] || { printf 'FAIL left in the working directory:\n%s\n' "$left" >>"$logs/$s.log"; code=1; }
  line "$s" $code "$logs/$s.log" $(($(date +%s) - start))
done

skipped=$(cat "$logs"/*.log | grep -h '^note: .*skipped\|^\[windows\] skipped' | sort | uniq -c | sed 's/^ *//')
[ -z "$skipped" ] || printf 'skipped:\n%s\n' "$skipped" | sed '2,$s/^/  /'
[ $failed = 0 ]
