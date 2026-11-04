#!/bin/sh
# r2_platform.sh: round-2 platform acceptance (DESIGN.md 12.21 P): links made,
# detected and removed by sys_make_link / sys_is_link / sys_remove_link, and
# sys_remove_tree removing a link without touching its target, on Linux (head
# and v0.17.0) and under wine (v0.17.0 Windows, Linux-form paths through Z:).
#
#   sh tests/r2_platform.sh
set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$here" || exit 1
export WINEDEBUG=-all
out=/tmp/opencode/mcheck
fails=0

echo "== build"
tools/mcheck.sh tests/platform_driver.mettle >/tmp/opencode/r2_platform.build.log 2>&1
cat /tmp/opencode/r2_platform.build.log
if grep -q "FAILED" /tmp/opencode/r2_platform.build.log; then
  echo "r2_platform: build failed"
  exit 1
fi
if grep "ok (" /tmp/opencode/r2_platform.build.log | grep -qv "(0 warnings)"; then
  echo "r2_platform: warnings"
  fails=$((fails + 1))
fi

base=/tmp/opencode/r2_platform.$$
rm -rf "$base"
mkdir -p "$base"

run_case() {
  label="$1"; shift
  dir="$1"; shift
  host_dir="$1"; shift
  echo "== $label"
  if "$@" "$dir" >"$base/$label.log" 2>&1 && grep -q " 0 failed" "$base/$label.log"; then
    tail -1 "$base/$label.log"
  else
    cat "$base/$label.log"
    echo "FAIL $label"
    fails=$((fails + 1))
  fi
  if [ -e "$host_dir" ] || [ -L "$host_dir" ]; then
    echo "FAIL $label: $host_dir left behind"
    fails=$((fails + 1))
  fi
}

run_case head "$base/head" "$base/head" "$out/platform_driver.head"
run_case l017 "$base/l017" "$base/l017" "$out/platform_driver.l017"
run_case w017 "Z:$base/w017" "$base/w017" wine "$out/platform_driver.exe"
# A relative directory under wine (the runner cds to the Linux form of cwd).
cd "$base" || exit 1
run_case l017rel "lrel" "$base/lrel" "$out/platform_driver.l017"
run_case w017rel "rel" "$base/rel" wine "$out/platform_driver.exe"
cd "$here" || exit 1

rm -rf "$base"
if [ $fails -ne 0 ]; then
  echo "r2_platform: $fails failure(s)"
  exit 1
fi
echo "r2_platform: all passed"
