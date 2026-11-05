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
# after NAME FILE INPUT ERE: the first answer line after "mettle> INPUT" (program ticks and held-lines notices skipped) matches ERE
after() {
  got=$(awk -v want="mettle> $3" 'f && !/^tick / && !/^  \(.* held, :log\)$/ { print; exit } $0 == want { f = 1 }' "$2")
  if printf '%s\n' "$got" | grep -qE -- "$4"; then ok "$1"; else bad "$1 (after \`$3\` wanted: $4, got: $got)" "$(cat "$2")"; fi
}
# block FILE INPUT: the answer lines after "mettle> INPUT", up to the next prompt (program ticks and held-lines notices skipped)
block() { awk -v want="mettle> $2" 'f && /^mettle> / { exit } f && !/^tick / && !/^  \(.* held, :log\)$/ { print } $0 == want { f = 1 }' "$1"; }
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
sh "$here/tools/mcompile.sh" "$here/src/main.mettle" -o "$T/mbuild" >"$T/build.log" 2>&1 || { cat "$T/build.log"; exit 1; }
MB="$T/mbuild"

echo "== the prompt redrawn above program output (a fake terminal)"
sh "$here/tools/mcompile.sh" "$here/tests/unit/shell_term_test.mettle" -o "$T/shell_term_test" >"$T/term.log" 2>&1 && "$T/shell_term_test" >"$T/term.out" 2>&1
has "redraw unit test" "$T/term.out" '^shell_term_test: [0-9]+ passed, 0 failed$'

echo "== lib/tui: UTF-8, widths, the diff renderer, keys"
sh "$here/tools/mcompile.sh" "$here/tests/unit/tui_test.mettle" -o "$T/tui_test" >"$T/tui.log" 2>&1 && "$T/tui_test" >"$T/tui.out" 2>&1
has "tui unit test" "$T/tui.out" '^tui_test: [0-9]+ passed, 0 failed$'

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
has "help title" "$T/help.out" '^shell - a shell inside the running program$'
has "help usage" "$T/help.out" '^  usage: mbuild shell \[BIN\]'
has "help doc" "$T/help.out" '^Doc: docs/project.md$'

echo "== non-shell builds get the empty shell_point"
"$MB" build >"$T/plain.out" 2>&1
code=$?
if [ $code -eq 0 ] && timeout 1 "$W/build/linux/debug/live_demo" 2>&1 | grep -q '^tick 0 '; then ok "plain build runs"; else bad "plain build runs" "$(cat "$T/plain.out")"; fi

echo "== a session (--stream)"
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
timeout 60 "$MB" shell --stream <"$T/in1" >"$T/s1.out" 2>&1
code=$?
[ $code -eq 0 ] && ok "quits with 0" || bad "quits with 0 (got $code)" "$(cat "$T/s1.out")"
has "builds with --live" "$T/s1.out" '^ +Compiling live_demo \(linux, debug\)$'
has "--stream: status line" "$T/s1.out" '^ +Running build/.*/live_demo; its output streams above the prompt'
if grep -q 'new lines\? held' "$T/s1.out"; then bad "--stream holds nothing" "$(cat "$T/s1.out")"; else ok "--stream holds nothing"; fi
after "statement" "$T/s1.out" "world.food = 1000;" '^ok$'
has "the statement changed the program" "$T/s1.out" '^tick [0-9]+  pop [0-9]+  food (9[0-9][0-9]|1[0-9]{3})  \(steady\)$'
after "bool expression" "$T/s1.out" "world.food >= 900" '^true$'
after "struct printed field by field" "$T/s1.out" "world" '^World \{ tick: [0-9]+, pop: [0-9]+, food: [0-9]+ \}$'
after "string" "$T/s1.out" "rule_name()" '^"steady"$'
after "float" "$T/s1.out" "1.5 * 2.0" '^3\.0$'
after "call" "$T/s1.out" "harvest(10)" '^5$'
after "redefine" "$T/s1.out" "fn harvest(pop: int32) -> int32 { return pop * 3; }" '^redefined harvest$'
redef=$(awk '/^mettle> harvest\(10\)/ { f = 1; next } f && !/^tick / && !/^  \(.* held, :log\)$/ { print; f = 0 }' "$T/s1.out" | tr '\n' ' ')
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

echo "== discovery and output"
cat >"$T/in5" <<'EOF'
ls
ls rules
apropos FOOD
apropos zzzq
explain harvest
explain world
explain World
help
:mute
world.pop
:log 2
:unmute
:mute
:q
EOF
timeout 60 "$MB" shell <"$T/in5" >"$T/s5.out" 2>&1
# lines BLOCK ERE: a line of BLOCK matches ERE
lines() { printf '%s\n' "$1" | grep -qE -- "$2"; }
blk=$(block "$T/s5.out" ls)
lines "$blk" '^src/main\.mettle$' && lines "$blk" '^src/rules\.mettle$' && ok "ls: grouped by file" || bad "ls: grouped by file" "$blk"
lines "$blk" '^  fn harvest\(pop: int32\) -> int32 +food gathered this tick$' && ok "ls: signature and doc" || bad "ls: signature and doc" "$blk"
lines "$blk" '^  var world: World +the one world' && lines "$blk" '^  struct World \{ tick: int32; pop: int32; food: int32 \} +the simulation' && ok "ls: globals and structs" || bad "ls: globals and structs" "$blk"
blk=$(block "$T/s5.out" "ls rules")
lines "$blk" '^  fn grow' && ! lines "$blk" 'world|src/main' && ok "ls FILE: that file only" || bad "ls FILE: that file only" "$blk"
blk=$(block "$T/s5.out" "apropos FOOD")
[ "$blk" = "$(printf 'src/rules.mettle\n  fn harvest(pop: int32) -> int32  food gathered this tick')" ] && ok "apropos: a hit, any case" || bad "apropos: a hit, any case" "$blk"
after "apropos: a miss" "$T/s5.out" "apropos zzzq" '^nothing matches zzzq$'
blk=$(block "$T/s5.out" "explain harvest")
lines "$blk" '^fn harvest\(pop: int32\) -> int32  src/rules\.mettle:[0-9]+$' && lines "$blk" '^  food gathered this tick$' && ok "explain fn" || bad "explain fn" "$blk"
blk=$(block "$T/s5.out" "explain world")
lines "$blk" '^var world: World  src/main\.mettle:[0-9]+$' && lines "$blk" '^  the one world' && ok "explain global: type and doc" || bad "explain global: type and doc" "$blk"
lines "$blk" '^  = World \{ tick: [0-9]+, pop: [0-9]+, food: [0-9]+ \}$' && ok "explain global: its value" || bad "explain global: its value" "$blk"
blk=$(block "$T/s5.out" "explain World")
lines "$blk" '^struct World  src/main\.mettle:[0-9]+$' && lines "$blk" '^  food: int32 +food in store$' && ok "explain struct: fields and their docs" || bad "explain struct: fields and their docs" "$blk"
blk=$(block "$T/s5.out" help)
n=$(printf '%s\n' "$blk" | grep -cxE 'evaluate|change code|discover|output|session')
[ "$n" = 5 ] && lines "$blk" '^  apropos TEXT +.*: apropos food$' && ok "help: grouped, with examples" || bad "help: grouped, with examples" "$blk"
has "held by default: status line" "$T/s5.out" '^ +Running build/.*/live_demo; its output is held \(:log to see it, :unmute to stream it\)\. help for help, :q to leave$'
early=$(awk '$0 == "mettle> :log 2" { exit } /^tick / { print }' "$T/s5.out")
[ -z "$early" ] && ok "output is held by default" || bad "output is held by default" "$early"
has "held lines are counted before a prompt" "$T/s5.out" '^  \([0-9]+ new lines? held, :log\)$'
n=$(awk '$0 == "mettle> :log 2" { f = 1; next } f && /^mettle> / { exit } f' "$T/s5.out" | grep -c '^tick ')
[ "$n" = 2 ] && ok ":log N: the last N lines" || bad ":log N: the last N lines (got $n)" "$(cat "$T/s5.out")"
after ":unmute" "$T/s5.out" ":unmute" '^streaming the program'"'"'s output'
after ":mute" "$T/s5.out" ":mute" '^holding the program'"'"'s output'
gone "the program stops (discovery session)" "$EXE"

echo "== held output: a program that exits"
W2="$T/live2"
mkdir -p "$W2/src"
cp "$W/mbuild.mettle" "$W2/"
cp "$here/examples/live/src/rules.mettle" "$W2/src/"
sed -e 's/< 100000/< 12/' -e 's/return 0;/return 3;/' "$W/src/main.mettle" >"$W2/src/main.mettle"
cd "$W2"
rm -f "$T/fifo2"
mkfifo "$T/fifo2"
timeout 60 "$MB" shell <"$T/fifo2" >"$T/s6.out" 2>&1 &
sp=$!
exec 3>"$T/fifo2"
i=0
while kill -0 $sp 2>/dev/null && [ $i -lt 400 ]; do i=$((i + 1)); sleep 0.05; done
if kill -0 $sp 2>/dev/null; then bad "the shell leaves when the program exits"; else ok "the shell leaves when the program exits"; fi
exec 3>&-
wait $sp
has "exit code shown" "$T/s6.out" '^  the program exited with code 3$'
n=$(grep -c '^tick ' "$T/s6.out")
[ "$n" = 5 ] && has "the last line is shown" "$T/s6.out" '^tick 11 ' && ok "only its last 5 lines are shown" || bad "last 5 lines shown (got $n tick lines)" "$(cat "$T/s6.out")"
cd "$W"

echo "== pause, step, resume, watch, pause when, edit"
printf '#!/bin/sh\nsed -i "s|return pop / 2;|return pop * 3;|" "$1"\n' >"$T/ed.sh"
chmod +x "$T/ed.sh"
cat >"$T/in6" <<'EOF'
pause
world.tick
status
world.food = 5000;
world.tick
status
step
status
world.tick
resume
status
watch world.pop * 2
watch
unwatch world.pop * 2
watch
pause when world.food > 6000
world.food = 7000;
world.tick
status
pause when
resume
edit harvest
harvest(10)
status
edit harvest
undo harvest
harvest(10)
:q
EOF
EDITOR="$T/ed.sh" timeout 60 "$MB" shell <"$T/in6" >"$T/s6.out" 2>&1
after "pause" "$T/s6.out" "pause" '^paused at tick [0-9]+$'
p1=$(block "$T/s6.out" pause | sed -n 's/^paused at tick //p')
st=$(awk '/^mettle> status$/ { f = 1; next } f && /^(paused|running)/ { print; f = 0 }' "$T/s6.out")
s1=$(printf '%s\n' "$st" | sed -n 1p)
s2=$(printf '%s\n' "$st" | sed -n 2p)
s3=$(printf '%s\n' "$st" | sed -n 3p)
[ -n "$p1" ] && [ "$s1" = "paused at tick $p1 · 0 patches" ] && [ "$s2" = "$s1" ] && ok "paused: the tick stays" || bad "paused: the tick stays (pause at $p1; $s1 / $s2)" "$(cat "$T/s6.out")"
wt=$(awk '/^mettle> world.tick$/ { f = 1; next } f && /^[0-9]+$/ { print; f = 0 }' "$T/s6.out" | tr '\n' ' ')
w1=$(echo $wt | cut -d' ' -f1); w2=$(echo $wt | cut -d' ' -f2); w3=$(echo $wt | cut -d' ' -f3)
[ -n "$w1" ] && [ "$w1" = "$w2" ] && [ "$w3" = $((w2 + 1)) ] && ok "paused: the program's state stays; step runs one tick" || bad "world.tick while paused and after step ($wt)" "$(cat "$T/s6.out")"
[ "$s3" = "paused at tick $((p1 + 1)) · 0 patches" ] && ok "step: one tick on, paused again" || bad "step: one tick on ($s3)" "$(cat "$T/s6.out")"
after "step answer" "$T/s6.out" "step" "^paused at tick $((p1 + 1))\$"
after "resume" "$T/s6.out" "resume" '^running from tick [0-9]+$'
s4=$(printf '%s\n' "$st" | sed -n 4p)
case "$s4" in "running · tick "*) ok "running again";; *) bad "running again ($s4)" "$(cat "$T/s6.out")";; esac
after "watch EXPR" "$T/s6.out" "watch world.pop * 2" '^watching world\.pop \* 2$'
blk=$(awk '$0 == "mettle> watch" { n++; f = 1; next } f && /^mettle> / { f = 0 } f && n == 1' "$T/s6.out")
lines "$blk" '^world = World \{ tick: [0-9]+, pop: [0-9]+, food: [0-9]+ \}$' && lines "$blk" '^world\.pop \* 2 = [0-9]+$' && ok "watch: the globals and EXPR, with values" || bad "watch: values" "$blk"
blk=$(awk '$0 == "mettle> watch" { n++; f = 1; next } f && /^mettle> / { f = 0 } f && n == 2' "$T/s6.out")
lines "$blk" '^world = ' && ! lines "$blk" 'world\.pop \* 2' && ok "unwatch" || bad "unwatch" "$blk"
after "pause when" "$T/s6.out" "pause when world.food > 6000" '^will pause when world\.food > 6000$'
s5=$(printf '%s\n' "$st" | sed -n 5p)
case "$s5" in "paused at tick "*" · pause when world.food > 6000") ok "pause when: paused where it turned true";; *) bad "pause when: paused ($s5)" "$(cat "$T/s6.out")";; esac
after "pause when cleared" "$T/s6.out" "pause when" '^cleared: pause when world\.food > 6000$'
after "edit" "$T/s6.out" "edit harvest" '^redefined harvest$'
answers=$(awk '/^mettle> harvest\(10\)/ { f = 1; next } f && /^[0-9]+$/ { print; f = 0 }' "$T/s6.out" | tr '\n' ' ')
[ "$answers" = "30 5 " ] && ok "edit patches the saved text, undo NAME takes it back" || bad "edit then undo harvest (answers: $answers)" "$(cat "$T/s6.out")"
s6=$(printf '%s\n' "$st" | sed -n 6p)
case "$s6" in *" · 1 patch") ok "status counts the patch";; *) bad "status counts the patch ($s6)" "$(cat "$T/s6.out")";; esac
has "edit: nothing changed the second time" "$T/s6.out" '^no changes to harvest$'
after "undo NAME" "$T/s6.out" "undo harvest" '^undone: harvest as before$'
cmp -s "$here/examples/live/src/rules.mettle" "$W/src/rules.mettle" && ok "edit leaves src/ alone" || bad "edit leaves src/ alone"
gone "the program stops (pause session)" "$EXE"

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

echo "== the full screen (mbuild-shell in a pty)"
if ! command -v python3 >/dev/null 2>&1; then
  echo "note: tui pty test skipped (no python3)"
else
  ( cd "$here" && "$MB" build mbuild-shell -t host --quiet ) >"$T/tui-build.log" 2>&1 && cp "$here/build/linux/debug/mbuild-shell" "$T/mbuild-shell"
  [ -x "$T/mbuild-shell" ] && ok "mbuild builds mbuild-shell (lib/tui by path)" || bad "mbuild builds mbuild-shell" "$(cat "$T/tui-build.log")"
  for r in "" $(case " ${MBTEST_MODES:-debug release} " in *" release "*) echo --release ;; esac); do
    sh "$here/tools/mcompile.sh" $r "$here/cmd/mbuild-shell/main.mettle" -o "$T/mbuild-shell.chk" >"$T/tui-chk.log" 2>&1
    n=$(grep -c '^warning' "$T/tui-chk.log")
    [ "$n" = 0 ] && ok "mbuild-shell ${r:-debug}: no warnings" || bad "mbuild-shell ${r:-debug}: no warnings" "$(cat "$T/tui-chk.log")"
  done
  rm -f "$T/mbuild-shell.chk"
  mkdir -p "$T/cap"
  timeout 240 python3 -I "$here/tests/e2e/shell_tui.py" "$MB" "$W" "$T/cap" >"$T/tui.pty.out" 2>&1
  sed 's/^/  /' "$T/tui.pty.out" | grep -v '^  PASS' | grep -v 'shell_tui:'
  p=$(grep -c '^PASS ' "$T/tui.pty.out"); f=$(grep -c '^FAIL ' "$T/tui.pty.out")
  pass=$((pass + p)); failn=$((failn + f))
  grep -q '^shell_tui: [0-9]* passed, 0 failed$' "$T/tui.pty.out" && ok "tui pty session ran to the end" || bad "tui pty session ran to the end" "$(tail -20 "$T/tui.pty.out")"
  gone "the program stops (tui)" "$EXE"
  rm -f "$T/mbuild-shell"
fi

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
