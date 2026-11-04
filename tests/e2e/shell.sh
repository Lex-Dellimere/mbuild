#!/bin/sh
# shell.sh: `mbuild shell` on a copy of examples/live, input piped in (the non-tty path); Linux only.
#   METTLE=dev-compiler sh tests/e2e/shell.sh   (scratch: $MBTEST_TMP)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
T="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/shell}"
rm -rf "$T"
mkdir -p "$T"
export LC_ALL=C NO_COLOR=1 METTLE
unset MBUILD_COLOR
export MBUILD_HOME="$T/home"
export MBUILD_REGISTRY="$T/reg"

pass=0
failn=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -40; }
# has NAME FILE ERE: a line of FILE matches ERE
has() { if grep -qE -- "$3" "$2"; then ok "$1"; else bad "$1 (wanted: $3)" "$(cat "$2")"; fi; }
# after NAME FILE INPUT ERE: the first answer line after "mettle> INPUT" (program ticks skipped) matches ERE
after() {
  got=$(awk -v want="mettle> $3" 'f && !/^tick / { print; exit } $0 == want { f = 1 }' "$2")
  if printf '%s\n' "$got" | grep -qE -- "$4"; then ok "$1"; else bad "$1 (after \`$3\` wanted: $4, got: $got)" "$(cat "$2")"; fi
}
# gone NAME EXE: no process runs EXE
gone() {
  i=0
  while ps -eo args | grep -qxF -- "$2"; do
    i=$((i + 1))
    [ $i -gt 100 ] && { bad "$1" "$(ps -eo pid,args | grep -F -- "$2")"; return; }
    sleep 0.05
  done
  ok "$1"
}

[ "$(uname -s)" = Linux ] || { echo "note: shell suite skipped (Linux only)"; echo "shell: 0 passed, 0 failed"; exit 0; }

echo "== mbuild"
"$METTLE" --build "$here/src/main.mettle" -o "$T/mbuild" >"$T/build.log" 2>&1 || { cat "$T/build.log"; exit 1; }
MB="$T/mbuild"

# The live example, ticking faster and longer.
W="$T/live"
mkdir -p "$W/src"
cp "$here/examples/live/mbuild.mettle" "$W/"
cp "$here/examples/live/src/rules.mettle" "$W/src/"
sed -e 's/Sleep(500)/Sleep(40)/' -e 's/< 600/< 100000/' "$here/examples/live/src/main.mettle" >"$W/src/main.mettle"
EXE="$W/build/linux/debug/shell/live_demo"
cd "$W"

echo "== help"
"$MB" help shell >"$T/help.out" 2>&1
has "help title" "$T/help.out" '^shell - a prompt inside the running program$'
has "help usage" "$T/help.out" '^  usage: mbuild shell \[BIN\]'
has "help doc" "$T/help.out" '^Doc: docs/project.md$'

echo "== non-shell builds get the empty shell_point"
"$MB" build >"$T/plain.out" 2>&1
code=$?
if [ $code -eq 0 ] && timeout 1 "$W/build/linux/debug/live_demo" 2>&1 | grep -q '^tick 0 '; then ok "plain build runs"; else bad "plain build runs" "$(cat "$T/plain.out")"; fi

echo "== a session"
cat >"$T/in1" <<'EOF'
world.food = 1000;
world.food >= 900
world
rule_name()
1.5 * 2.0
harvest(10)
fn harvest(pop: int32) -> int32 { return pop * 3; }
harvest(10)
undo
harvest(10)
undo
h grow
h nosuch
i world
i &world
&world
nosuch + 1
world.pop
:q
EOF
timeout 60 "$MB" shell <"$T/in1" >"$T/s1.out" 2>&1
code=$?
[ $code -eq 0 ] && ok "quits with 0" || bad "quits with 0 (got $code)" "$(cat "$T/s1.out")"
has "builds with --live" "$T/s1.out" '^ +Compiling live_demo \(linux, debug\)$'
after "statement" "$T/s1.out" "world.food = 1000;" '^ok$'
has "the statement changed the program" "$T/s1.out" '^tick [0-9]+  pop [0-9]+  food (9[0-9][0-9]|1[0-9]{3})  \(steady\)$'
after "bool expression" "$T/s1.out" "world.food >= 900" '^true$'
after "struct printed field by field" "$T/s1.out" "world" '^World \{ tick: [0-9]+, pop: [0-9]+, food: [0-9]+ \}$'
after "string" "$T/s1.out" "rule_name()" '^"steady"$'
after "float" "$T/s1.out" "1.5 * 2.0" '^3\.0$'
after "call" "$T/s1.out" "harvest(10)" '^5$'
after "redefine" "$T/s1.out" "fn harvest(pop: int32) -> int32 { return pop * 3; }" '^redefined harvest$'
redef=$(awk '/^mettle> harvest\(10\)/ { f = 1; next } f && !/^tick / { print; f = 0 }' "$T/s1.out" | tr '\n' ' ')
[ "$redef" = "5 30 5 " ] && ok "the redefinition runs, undo takes it back" || bad "redefinition then undo (answers: $redef)" "$(cat "$T/s1.out")"
has "undo once more: nothing" "$T/s1.out" '^nothing to undo$'
has "h signature" "$T/s1.out" '^fn grow\(pop: int32, food: int32\) -> int32  src/rules\.mettle:[0-9]+$'
has "h doc comment" "$T/s1.out" '^  population next tick$'
has "h unknown" "$T/s1.out" '^error: no nosuch in this project or its packages'
has "i type" "$T/s1.out" '^World  struct, src/main\.mettle:[0-9]+$'
has "i fields" "$T/s1.out" '^  food: int32$'
has "i of a pointer" "$T/s1.out" '^World\*  struct, src/main\.mettle:[0-9]+$'
after "pointer to a struct" "$T/s1.out" "&world" '^&World \{ tick: '
has "compile error shown" "$T/s1.out" "^error\[E[0-9]+\]: Undefined variable 'nosuch'$"
after "int after an error" "$T/s1.out" "world.pop" '^[0-9]+$'
if grep -q '^\[live\] patch [0-9]*: ' "$T/s1.out"; then bad "live runtime lines hidden" "$(cat "$T/s1.out")"; else ok "live runtime lines hidden"; fi
gone "the program stops with the shell" "$EXE"
cmp -s "$here/examples/live/src/rules.mettle" "$W/src/rules.mettle" && ok "redefinitions leave src/ alone" || bad "redefinitions leave src/ alone"

echo "== r: the files on disk"
rm -f "$T/fifo"
mkfifo "$T/fifo"
timeout 60 "$MB" shell <"$T/fifo" >"$T/s2.out" 2>&1 &
sp=$!
exec 3>"$T/fifo"
# waitfor ERE: up to 20s for a line of the session's output
waitfor() { i=0; while ! grep -qE -- "$1" "$T/s2.out"; do i=$((i + 1)); [ $i -gt 400 ] && return 1; sleep 0.05; done; }
printf 'harvest(10)\n' >&3
waitfor '^5$'
sed 's|return pop / 2;|return pop * 7;|' "$here/examples/live/src/rules.mettle" >"$W/src/rules.mettle"
printf 'r\nharvest(10)\nundo\nharvest(10)\nr\n:q\n' >&3
exec 3>&-
wait $sp
after "r patches the edit" "$T/s2.out" "r" '^patched \(1 file\)$'
answers=$(awk '/^mettle> harvest\(10\)/ { f = 1; next } f && !/^tick / { print; f = 0 }' "$T/s2.out" | tr '\n' ' ')
[ "$answers" = "5 70 5 " ] && ok "r takes the new code, undo the old back" || bad "r then undo (answers: $answers)" "$(cat "$T/s2.out")"
cp "$here/examples/live/src/rules.mettle" "$W/src/"
gone "the program stops (r session)" "$EXE"

echo "== a program without shell_point"
sed -e '/shell_point();/d' "$W/src/main.mettle" >"$T/main.tmp" && cp "$T/main.tmp" "$W/src/main.mettle"
printf 'world.pop\n:q\n' >"$T/in3"
MBUILD_SHELL_TIMEOUT=1500 timeout 60 "$MB" shell <"$T/in3" >"$T/s3.out" 2>&1
has "timeout message" "$T/s3.out" '^error: no answer in 1s: the program never reached shell_point\(\)$'
has "timeout help" "$T/s3.out" 'call `shell_point\(\);` \(import "mbuild/shell"\) next to its `quiesce;`'
gone "the program stops (no shell_point)" "$EXE"

echo "== --local"
cat >"$T/in4" <<'EOF'
harvest(10)
var x = 7;
grow(x, 100)
fn twice(a: int32) -> int32 { return a * 2; }
twice(x)
rule_name()
h harvest
:q
EOF
timeout 60 "$MB" shell --local <"$T/in4" >"$T/s4.out" 2>&1
after "local call" "$T/s4.out" "harvest(10)" '^5$'
after "local var" "$T/s4.out" "var x = 7;" '^ok$'
after "local binding kept" "$T/s4.out" "grow(x, 100)" '^8$'
after "local fn" "$T/s4.out" "fn twice(a: int32) -> int32 { return a * 2; }" '^defined twice$'
after "local fn called" "$T/s4.out" "twice(x)" '^14$'
after "local string" "$T/s4.out" "rule_name()" '^"steady"$'
has "local h" "$T/s4.out" '^fn harvest\(pop: int32\) -> int32  src/rules\.mettle:[0-9]+$'

echo "shell: $pass passed, $failn failed"
[ $failn -eq 0 ]
