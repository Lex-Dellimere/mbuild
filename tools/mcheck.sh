#!/bin/sh
# mcheck.sh: build a Mettle entry file with the dev compiler, debug and
# --release, and fail on any warning.
#
#   tools/mcheck.sh ENTRY [--run] [-- ARGS...]   --run: run both builds; stdout and exit codes must agree, exit 0
#   tools/mcheck.sh --all-drivers                every tests/unit/*_test.mettle
#
# METTLE: the dev compiler (default ../Mettle/bin/mettle). METTLE_WIN: a Windows
# dev compiler (mettle.exe) for a third build under wine; skipped when unset.
# Outputs: ${TMPDIR:-/tmp}/mbuild-mcheck/<stem>.{debug,release,exe} and their .log.

set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
out="${TMPDIR:-/tmp}/mbuild-mcheck"
export WINEDEBUG=-all
mkdir -p "$out"

usage() { echo "usage: $0 ENTRY [--run] [-- ARGS...] | --all-drivers" >&2; exit 2; }
[ $# -ge 1 ] || usage

# build LABEL OUTPUT COMPILER-ARGV...: one compile, its warnings counted.
build() {
  label="$1"; o="$2"; shift 2
  if ! "$@" -o "$o" >"$o.log" 2>&1; then
    echo "[$label] FAILED"
    sed 's/^/    /' "$o.log" | head -60
    return 1
  fi
  n=$(grep -c '^warning' "$o.log")
  if [ "$n" != 0 ]; then
    echo "[$label] $n warnings"
    sed 's/^/    /' "$o.log" | head -60
    return 1
  fi
  echo "[$label] ok"
}

# check ENTRY RUN [ARGS...]
check() {
  entry="$1"; run="$2"; shift 2
  stem="$(basename "$entry" .mettle)"
  echo "== $stem"
  st=0
  build debug "$out/$stem.debug" "$METTLE" --build "$entry" || st=1
  build release "$out/$stem.release" "$METTLE" --build --release "$entry" || st=1
  if [ -n "${METTLE_WIN:-}" ]; then
    build windows "$out/$stem.exe" wine "$METTLE_WIN" --build "$entry" || st=1
  else
    echo "[windows] skipped: METTLE_WIN names no Windows dev compiler"
  fi
  [ $run = 1 ] && [ $st = 0 ] || return $st
  "$out/$stem.debug" "$@" >"$out/$stem.debug.out" 2>"$out/$stem.debug.err"; dc=$?
  "$out/$stem.release" "$@" >"$out/$stem.release.out" 2>"$out/$stem.release.err"; rc=$?
  if [ $dc != 0 ]; then
    echo "[run] debug exit $dc"
    cat "$out/$stem.debug.out" "$out/$stem.debug.err" | grep -v '^PASS' | sed 's/^/    /' | head -60
    st=1
  fi
  if [ $dc != $rc ]; then
    echo "[run] exit codes differ: debug $dc, release $rc"
    st=1
  elif ! cmp -s "$out/$stem.debug.out" "$out/$stem.release.out"; then
    echo "[run] stdout differs between debug and release"
    diff "$out/$stem.debug.out" "$out/$stem.release.out" | sed 's/^/    /' | head -40
    st=1
  fi
  if [ -n "${METTLE_WIN:-}" ]; then
    wine "$out/$stem.exe" "$@" >"$out/$stem.exe.out" 2>&1; wc=$?
    [ $wc = $dc ] || { echo "[run] windows exit $wc, linux $dc"; st=1; }
  fi
  [ $st = 0 ] && echo "[run] ok ($(tail -1 "$out/$stem.debug.out"))"
  return $st
}

if [ "$1" = "--all-drivers" ]; then
  status=0
  for f in "$here"/tests/unit/*_test.mettle; do
    check "$f" 0 || status=1
  done
  exit $status
fi
entry="$1"; shift
run=0
if [ "${1:-}" = "--run" ]; then run=1; shift; fi
if [ "${1:-}" = "--" ]; then shift; fi
check "$entry" $run "$@"
