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
{ TMPDIR="$base" sh "$here/tools/mcheck.sh" "$here/src/main.mettle" --run && TMPDIR="$base" sh "$here/tools/mcheck.sh" --all-drivers; } >"$logs/mcheck.log" 2>&1
code=$?
n=$(grep -c '^== ' "$logs/mcheck.log")
echo "$n entries, $(grep -c '^\[\(debug\|release\|windows\)\] \(FAILED\|[0-9]* warnings\)' "$logs/mcheck.log") failed builds" >>"$logs/mcheck.log"
line mcheck $code "$logs/mcheck.log" $(($(date +%s) - start))

suites="${*:-build config registry deps api components init native toolchain platform}"
for s in $suites; do
  start=$(date +%s)
  MBTEST_TMP="$base/$s" sh "$here/tests/e2e/$s.sh" >"$logs/$s.log" 2>&1
  line "$s" $? "$logs/$s.log" $(($(date +%s) - start))
done

skipped=$(cat "$logs"/*.log | grep -h '^note: .*skipped\|^\[windows\] skipped' | sort | uniq -c | sed 's/^ *//')
[ -z "$skipped" ] || printf 'skipped:\n%s\n' "$skipped" | sed '2,$s/^/  /'
[ $failed = 0 ]
