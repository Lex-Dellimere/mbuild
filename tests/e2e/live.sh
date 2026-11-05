#!/bin/sh
# live.sh: the live preview: mb_watch, the events file, mbuild/live, --preview; under
# `mbuild live` and `mbuild shell`, with a debug and a release mbuild. Linux only.
#   METTLE=dev-compiler sh tests/e2e/live.sh   (scratch: $MBTEST_TMP)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
T="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/live}"
rm -rf "$T"
mkdir -p "$T"
export LC_ALL=C NO_COLOR=1 METTLE
unset MBUILD_COLOR MBUILD_LIVE_EVENTS MBUILD_PREVIEW
export MBUILD_HOME="$T/home"
export MBUILD_REGISTRY="$T/reg"

pass=0
failn=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -40; }
# waitfor NAME FILE ERE: up to 20 s for a line of FILE to match ERE
waitfor() {
  i=0
  while ! grep -qE -- "$3" "$2" 2>/dev/null; do
    i=$((i + 1))
    [ $i -gt 400 ] && { bad "$1 (wanted: $3)" "$(cat "$2" 2>/dev/null)"; return 1; }
    sleep 0.05
  done
  ok "$1"
}
# waitn NAME FILE ERE N: up to 20 s for N lines of FILE to match ERE
waitn() {
  i=0
  while [ "$(grep -cE -- "$3" "$2" 2>/dev/null)" -lt "$4" ]; do
    i=$((i + 1))
    [ $i -gt 400 ] && { bad "$1 (wanted $4 of: $3)" "$(cat "$2" 2>/dev/null)"; return 1; }
    sleep 0.05
  done
  ok "$1"
}
# same NAME WANT GOT: the two texts are equal
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$(printf 'wanted:\n%s\ngot:\n%s' "$2" "$3")"; fi; }

[ "$(uname -s)" = Linux ] || { echo "note: live suite skipped (Linux only)"; echo "live: 0 passed, 0 failed"; exit 0; }

W="$T/fx"
mkdir -p "$W/src" "$W/shaders" "$W/assets"
cat >"$W/mbuild.mettle" <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("fx", "0.1.0");
  mb_watch("shaders/**, assets/*.txt");
  mb_preview("right");
}
EOF
cat >"$W/src/main.mettle" <<'EOF'
import "std/io";
import "mbuild/live";
import "mbuild/shell";
import "rules";

extern fn usleep(us: uint32) -> int32 = "usleep";
extern fn getenv(name: cstring) -> cstring = "getenv";

fn main() -> int32 {
  println("active {mblive_active()} preview={getenv(\"MBUILD_PREVIEW\")}");
  var ev: MbLiveEvent;
  if (!mblive_active()) {
    println("next {mblive_next(&ev)}");
    return 0;
  }
  var i: int64 = 0;
  while (i < 3000) {
    quiesce;
    shell_point();
    while (mblive_next(&ev)) {
      println("ev {ev.kind}|{ev.path}|{ev.detail}");
      if (ev.kind == "removed" && ev.path == "assets/stop.txt") {
        println("val {val()}");
        return 3;
      }
    }
    usleep(10000);
    i = i + 1;
  }
  return 4;
}
EOF
# val on lines 1-3, then enough other functions that a patch takes a while (saves can land in it);
# written beside it and moved in, so a watcher never reads half a file
rules() {
  { printf 'export fn val() -> int64 {\n  return %s;\n}\n' "$1"
    awk 'BEGIN { for (i = 0; i < 1200; i++) printf "export fn f%d(a: int64) -> int64 {\n  var x: int64 = a + %d;\n  return x * 2;\n}\n", i, i }'
  } >"$T/rules.tmp"
  mv "$T/rules.tmp" "$W/src/rules.mettle"
}
RES='^ev (patched|built|patch-error)\|'

for kind in ${MBTEST_MODES:-debug release}; do
  echo "== mbuild ($kind)"
  flag=""
  [ $kind = release ] && flag="--release"
  sh "$here/tools/mcompile.sh" $flag "$here/src/main.mettle" -o "$T/mbuild-$kind" >"$T/build-$kind.log" 2>&1 || { cat "$T/build-$kind.log"; exit 1; }
  MB="$T/mbuild-$kind"
  cd "$W"
  rm -rf build .mbuild
  rules 1
  echo a >shaders/a.glsl
  echo b >shaders/b.glsl
  echo s >assets/stop.txt
  O="$T/live-$kind.out"

  echo "== mbuild live ($kind)"
  "$MB" live >"$O" 2>&1 &
  pid=$!
  waitfor "$kind: the program sees the events file and mb_preview" "$O" '^active true preview=right$' || { kill $pid; continue; }
  echo a2 >shaders/a.glsl
  waitfor "$kind: changed" "$O" '^ev changed\|shaders/a.glsl\|$'
  rm shaders/b.glsl
  waitfor "$kind: removed" "$O" '^ev removed\|shaders/b.glsl\|$'
  rules 2
  waitfor "$kind: patched" "$O" '^ev patched\|\|val$'
  rules '2 +'
  waitfor "$kind: patch-error with file:line:col" "$O" '^ev patch-error\|\|src/rules.mettle:2:[0-9]+: Expected an expression'
  rules 5
  waitn "$kind: fixed" "$O" '^ev patched\|\|val$' 2
  base=$(grep -cE "$RES" "$O")
  rules '5 +'
  waitn "$kind: a typo in the code that is running" "$O" "$RES" $((base + 1))
  rules 5
  waitn "$kind: the code restored to what runs" "$O" "$RES" $((base + 2))
  echo '// c' >>src/rules.mettle
  waitn "$kind: a save that changes nothing" "$O" "$RES" $((base + 3))
  rules 6
  sleep 0.4
  rules '6 +'
  waitn "$kind: two saves, the second in the patch of the first" "$O" "$RES" $((base + 5))
  sleep 4
  same "$kind: and no more than one result each" $((base + 5)) "$(grep -cE "$RES" "$O")"
  rules 5
  waitn "$kind: the last good code restored" "$O" "$RES" $((base + 6))
  rm assets/stop.txt
  wait $pid
  code=$?
  same "$kind: the events in order, as the program read them" "ev built||
ev changed|shaders/a.glsl|
ev removed|shaders/b.glsl|
ev patched||val
ev patch-error||src/rules.mettle:2:13: Expected an expression after '+', found ';'
ev patched||val
ev patch-error||src/rules.mettle:2:13: Expected an expression after '+', found ';'
ev built||
ev built||" "$(grep '^ev ' "$O" | sed -n 1,9p)"
  # a patch the first save's compile did or did not see decides patched or merged
  grep '^ev ' "$O" | sed -n 10p | grep -qE '^ev (patched\|\|val|patch-error\|\|src/rules.mettle:2:13: .*)$' && ok "$kind: the first of the two saves has a result" || bad "$kind: the first of the two saves has a result" "$(grep '^ev ' "$O")"
  same "$kind: the last of the two is a patch-error" "ev patch-error||src/rules.mettle:2:13: Expected an expression after '+', found ';'" "$(grep '^ev ' "$O" | sed -n 11p)"
  grep '^ev ' "$O" | sed -n 12p | grep -qE '^ev (patched\|\|val|built\|\|)$' && ok "$kind: the restore has a result" || bad "$kind: the restore has a result" "$(grep '^ev ' "$O")"
  same "$kind: then the stop" "ev removed|assets/stop.txt|" "$(grep '^ev ' "$O" | sed -n 13p)"
  grep -q '^val 5$' "$O" && ok "$kind: the fix is in" || bad "$kind: the fix is in" "$(cat "$O")"
  same "$kind: the exit code is the program's" 3 "$code"
  same "$kind: the events file ends with exited" "exited 3" "$(tail -1 .mbuild/live/fx.events)"
  grep -qx 'patched val' .mbuild/live/fx.events && ok "$kind: one patched line per function" || bad "$kind: one patched line per function" "$(cat .mbuild/live/fx.events)"

  echo "== --preview, and a build outside live ($kind)"
  echo s >assets/stop.txt
  "$MB" live --preview left >"$O.2" 2>&1 &
  pid=$!
  waitfor "$kind: --preview overrides mb_preview" "$O.2" '^active true preview=left$'
  rm assets/stop.txt
  wait $pid
  "$MB" live --preview middle >"$O.3" 2>&1
  grep -q 'preview takes left, right, top, bottom or off' "$O.3" && ok "$kind: a bad side is refused" || bad "$kind: a bad side is refused" "$(cat "$O.3")"
  "$MB" build >"$O.4" 2>&1 && "$W/build/linux/debug/fx" >"$O.5" 2>&1
  same "$kind: a plain build: inactive, no events" "active false preview=
next false" "$(cat "$O.5")"

  echo "== mbuild shell ($kind)"
  echo s >assets/stop.txt
  printf 'pause\nstep\nresume\n:log 50\n' | "$MB" shell --plain --preview left >"$T/shell-$kind.out" 2>&1
  grep -q '^active true preview=left$' "$T/shell-$kind.out" && ok "$kind: shell passes the preview hint" || bad "$kind: shell passes the preview hint" "$(cat "$T/shell-$kind.out")"
  same "$kind: shell emits paused and resumed" "built
paused
resumed
paused
resumed" "$(cat .mbuild/live/fx.events)"
  cd "$T"
done

echo "live: $pass passed, $failn failed"
[ $failn = 0 ]
