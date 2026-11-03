#!/bin/sh
# mcheck.sh: compile one Mettle entry file with every compiler mbuild must
# support, and optionally run each result.
#
#   tools/mcheck.sh <entry.mettle> [--run] [-- program args...]
#
# Compilers (override with the environment variables):
#   METTLE_HEAD   the compiler built from ../Mettle      (Linux, current source)
#   METTLE_L017   the v0.17.0 Linux release             (~/.mbuild/toolchains/v0.17.0/linux)
#   METTLE_W017   the v0.17.0 Windows release, via wine (~/.mbuild/toolchains/v0.17.0/windows)
#
# Outputs go to /tmp/opencode/mcheck/<stem>.{head,headrel,l017,exe}; headrel is a
# head --release build (compiled, not run), kept because head's optimizer has
# crashed on mbuild before. Exit status is
# non-zero when any compile fails (or any run fails, with --run).

set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
HEAD="${METTLE_HEAD:-$here/../Mettle/bin/mettle}"
L017="${METTLE_L017:-$HOME/.mbuild/toolchains/v0.17.0/linux/bin/mettle}"
W017="${METTLE_W017:-$HOME/.mbuild/toolchains/v0.17.0/windows/mettle.exe}"
export WINEDEBUG=-all

[ $# -ge 1 ] || { echo "usage: $0 <entry.mettle> [--run] [-- args...]" >&2; exit 2; }
entry="$1"; shift
run=0
if [ "${1:-}" = "--run" ]; then run=1; shift; fi
if [ "${1:-}" = "--" ]; then shift; fi

stem="$(basename "$entry" .mettle)"
outdir=/tmp/opencode/mcheck
mkdir -p "$outdir"
status=0

compile() {
  label="$1"; shift
  if "$@" >"$outdir/$stem.$label.log" 2>&1; then
    warnings=$(grep -c "^warning\|warning\[" "$outdir/$stem.$label.log" || true)
    echo "[$label] ok ($warnings warnings)"
  else
    echo "[$label] FAILED:"
    sed 's/^/    /' "$outdir/$stem.$label.log" | head -60
    status=1
    return 1
  fi
  return 0
}

compile head "$HEAD" --build "$entry" -o "$outdir/$stem.head" && [ $run = 1 ] && {
  echo "--- run head"; "$outdir/$stem.head" "$@" || { echo "[head] exit $?"; status=1; }
}
compile headrel "$HEAD" --build --release "$entry" -o "$outdir/$stem.headrel" || true
compile l017 "$L017" --build "$entry" -o "$outdir/$stem.l017" && [ $run = 1 ] && {
  echo "--- run l017"; "$outdir/$stem.l017" "$@" || { echo "[l017] exit $?"; status=1; }
}
compile w017 wine "$W017" --build "$entry" -o "$outdir/$stem.exe" && [ $run = 1 ] && {
  echo "--- run w017 (wine)"; wine "$outdir/$stem.exe" "$@" || { echo "[w017] exit $?"; status=1; }
}
exit $status
