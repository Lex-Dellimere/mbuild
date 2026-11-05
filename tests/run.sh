#!/bin/sh
# run.sh: every test: mcheck of mbuild and the unit drivers, then the tests/e2e suites, in parallel; one line per suite.
#   METTLE=dev-compiler sh tests/run.sh [-j N] [--quick] [SUITE...]   (SKIP_WINE=1 skips wine; logs in $MBTEST_TMP/logs)
#   -j N: N suites at once (default half the CPUs, at least 2). --quick: debug only, mcheck of main only.

set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
export METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
base="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}}"
logs="$base/logs"
[ "${SKIP_WINE:-0}" = 1 ] && unset METTLE_WIN
export SKIP_WINE="${SKIP_WINE:-0}"

# --one SUITE (from the pool below): the suite into logs/SUITE.log, "CODE SECONDS" into logs/SUITE.res
if [ "${1:-}" = --one ]; then
  s="$2"
  start=$(date +%s)
  if [ "$s" = mcheck ]; then
    { TMPDIR="$base" sh "$here/tools/mcheck.sh" "$here/src/main.mettle" --run &&
      if [ "${MBTEST_MODES:-}" = debug ]; then :; else TMPDIR="$base" sh "$here/tools/mcheck.sh" --all-drivers; fi; } >"$logs/mcheck.log" 2>&1
    code=$?
    n=$(grep -c '^== ' "$logs/mcheck.log")
    echo "$n entries, $(grep -c '^\[\(debug\|release\|windows\)\] \(FAILED\|[0-9]* warnings\)' "$logs/mcheck.log") failed builds" >>"$logs/mcheck.log"
  else
    # from an empty directory, which must stay empty (a dangling view once made garbage dirs)
    cwd="$base/cwd-$s"
    rm -rf "$cwd"
    mkdir -p "$cwd"
    ( cd "$cwd" && MBTEST_TMP="$base/$s" sh "$here/tests/e2e/$s.sh" ) >"$logs/$s.log" 2>&1
    code=$?
    left=$(cd "$cwd" && LC_ALL=C find . -mindepth 1 | cat -v)
    [ -z "$left" ] || { printf 'FAIL left in the working directory:\n%s\n' "$left" >>"$logs/$s.log"; code=1; }
  fi
  echo "$code $(($(date +%s) - start))" >"$logs/$s.res"
  exit 0
fi

jobs=$(($(nproc 2>/dev/null || echo 4) / 2))
[ $jobs -ge 2 ] || jobs=2
export MBTEST_MODES="debug release"
while [ $# -gt 0 ]; do
  case "$1" in
    -j) jobs="$2"; shift 2 ;;
    -j*) jobs="${1#-j}"; shift ;;
    --quick) MBTEST_MODES=debug; shift ;;
    *) break ;;
  esac
done
rm -rf "$logs"
mkdir -p "$logs"
export MBTEST_TMP="$base"

total=$(date +%s)
start=$total
# mbuild, mbuild-shell and every unit driver, each mode built once for all suites (tools/mcompile.sh);
# the suites start meanwhile and wait for a build they need (its .pending file)
export MBTEST_PREBUILT="$base/prebuilt"
rm -rf "$MBTEST_PREBUILT"
mkdir -p "$MBTEST_PREBUILT"
realpath "$METTLE" >"$MBTEST_PREBUILT/compiler"
( cd "$here" && for e in src/main.mettle cmd/mbuild-shell/main.mettle tests/unit/*_test.mettle; do
    for m in $MBTEST_MODES; do echo "$e $m"; done
  done ) | awk '{ print ($1 == "src/main.mettle" ? 0 : $2 == "debug" ? 1 : 2), $0 }' | sort -n | cut -d' ' -f2- >"$base/prebuild.list"
while read -r e m; do : >"$MBTEST_PREBUILT/$(printf %s "${e%.mettle}" | sed 's|/|_|g').$m.pending"; done <"$base/prebuild.list"
( xargs -P $jobs -n 2 sh -c 'k=$(printf %s "${2%.mettle}" | sed "s|/|_|g"); o="$MBTEST_PREBUILT/$k.$3"
    if [ $3 = release ]; then "$METTLE" --build --release "$1/$2" -o "$o"; else "$METTLE" --build "$1/$2" -o "$o"; fi >"$o.log" 2>&1 || rm -f "$o"
    rm -f "$o.pending"' _ "$here" <"$base/prebuild.list"
  echo $(($(date +%s) - start)) >"$base/prebuild.secs" ) &
prepid=$!

suites="${*:-build config registry mreg deps api components init native toolchain platform services shell live}"
# the slow ones first, so the pool ends together
slow="build live registry services mreg shell components config"
first=""
for s in $slow; do case " $suites " in *" $s "*) first="$first $s" ;; esac; done
rest=""
for s in $suites; do case " $first " in *" $s "*) ;; *) rest="$rest $s" ;; esac; done
printf '%s\n' $first mcheck $rest | xargs -P $jobs -I{} sh "$here/tests/run.sh" --one {}
wait $prepid

failed=0
# line NAME: the suite's summary line, or its last line, and its time
line() {
  read -r code secs <"$logs/$1.res" 2>/dev/null || { code=1; secs=?; }
  sum=$(grep -E '[0-9]+ passed, [0-9]+ failed' "$logs/$1.log" | tail -1 | sed 's/^.*: //')
  [ -n "$sum" ] || sum=$(tail -1 "$logs/$1.log")
  if [ "$code" = 0 ]; then
    printf 'ok    %-11s %s (%ss)\n' "$1" "$sum" "$secs"
  else
    printf 'FAIL  %-11s %s (%ss; %s)\n' "$1" "$sum" "$secs" "$logs/$1.log"
    failed=$((failed + 1))
  fi
}
echo "prebuilt    mbuild, mbuild-shell and the unit drivers, $MBTEST_MODES ($(cat "$base/prebuild.secs")s)"
for s in mcheck $suites; do line "$s"; done

skipped=$(cat "$logs"/*.log | grep -h '^note: .*skipped\|^\[windows\] skipped' | sort | uniq -c | sed 's/^ *//')
[ -z "$skipped" ] || printf 'skipped:\n%s\n' "$skipped" | sed '2,$s/^/  /'
echo "total       $(($(date +%s) - total))s, -j $jobs"
[ $failed = 0 ]
