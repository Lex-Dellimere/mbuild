#!/bin/sh
# platform.sh: path, sys, fs, proc and links (tests/unit/sys_test.mettle), also under wine with METTLE_WIN.
#   METTLE=dev-compiler sh tests/e2e/platform.sh   (scratch: $MBTEST_TMP; SKIP_WINE=1 skips wine)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
export METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
T="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/platform}"
rm -rf "$T"
mkdir -p "$T"
export MBUILD_HOME="$T/home" TMPDIR="$T"
[ "${SKIP_WINE:-0}" = 1 ] && unset METTLE_WIN

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -60; }
# unit NAME: tests/unit/NAME.mettle built debug and --release, both runs agree
unit() { if out=$(sh "$here/tools/mcheck.sh" "$here/tests/unit/$1.mettle" --run 2>&1); then ok "$1 ($(printf '%s\n' "$out" | sed -n 's/^\[run\] ok (.*: \(.*\))$/\1/p'))"; else bad "$1" "$out"; fi; }

unit sys_test
[ -n "${METTLE_WIN:-}" ] || echo "note: wine skipped (METTLE_WIN names no Windows dev compiler)"

echo
echo "platform: $pass passed, $failed failed"
[ $failed = 0 ]
