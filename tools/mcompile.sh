#!/bin/sh
# mcompile.sh [--release] ENTRY -o OUT: "$METTLE" --build [--release] ENTRY -o OUT, its output and
# exit code; a copy of run.sh's build of ENTRY when $MBTEST_PREBUILT has one from the same compiler.

set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
mode=debug
[ "$1" = --release ] && { mode=release; shift; }
entry="$1"; o="$3"
p="${MBTEST_PREBUILT:-}"
if [ -n "$p" ] && [ "$(cat "$p/compiler" 2>/dev/null)" = "$(realpath "$METTLE")" ]; then
  abs="$(cd "$(dirname "$entry")" && pwd)/$(basename "$entry")"
  key=$(printf '%s' "${abs#"$here"/}" | sed 's|/|_|g; s|\.mettle$||')
  n=0
  while [ -e "$p/$key.$mode.pending" ] && [ $n -lt 6000 ]; do sleep 0.1; n=$((n + 1)); done
  if [ -x "$p/$key.$mode" ]; then cp "$p/$key.$mode" "$o" && cat "$p/$key.$mode.log"; exit; fi
fi
if [ $mode = release ]; then exec "$METTLE" --build --release "$entry" -o "$o"; fi
exec "$METTLE" --build "$entry" -o "$o"
