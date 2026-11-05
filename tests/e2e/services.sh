#!/bin/sh
# services.sh: mb_service around `mbuild run`, mb_spawn and friends in a command, mbuild built debug and --release.
#   METTLE=dev-compiler sh tests/e2e/services.sh   (scratch: $MBTEST_TMP)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
S="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/services}"
rm -rf "$S"
mkdir -p "$S"
export LC_ALL=C NO_COLOR=1 METTLE
unset MBUILD_COLOR
export MBUILD_HOME="$S/home"

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -30; }
check() { name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$S/last.out" 2>/dev/null)"; fi; }
has() { grep -qF -- "$1" "$S/last.out"; }
hasnt() { ! grep -qF -- "$1" "$S/last.out"; }
code_is() { [ "$(cat "$S/last.code")" = "$1" ]; }
mb() { "$MB" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }
# gone PIDFILE: the process it names is not running
gone() { [ -s "$1" ] && ! kill -0 "$(cat "$1")" 2>/dev/null; }
# port_open PORT: something accepts on 127.0.0.1:PORT
port_open() { python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.5).close()' "$1" 2>/dev/null; }
# order: the status lines of last.out, verbs and subjects only
order() { sed -n 's/^ *\(Starting\|Ready\|Running\|Stopping\) \([a-z/]*\).*/\1 \2/p; s/^app got: .*/app/p' "$S/last.out" | tr '\n' ',' ; }

# four free ports from the kernel, so parallel suites do not collide
ports=$(python3 -c 'import socket
ss = [socket.socket() for _ in range(4)]
for s in ss: s.bind(("127.0.0.1", 0))
print(" ".join(str(s.getsockname()[1]) for s in ss))' 2>/dev/null)
if [ -n "$ports" ]; then
  set -- $ports
  P1=$1; P2=$2; P3=$3; P4=$4
else
  base=$((20000 + $$ % 20000))
  P1=$base; P2=$((base + 1)); P3=$((base + 2)); P4=$((base + 3))
fi

# proj DIR SERVICES...: a project with bins app and srv; each extra arg is a line of fn project()
proj() {
  d="$1"; shift
  mkdir -p "$d/src" "$d/tools"
  cp "$here/tests/fixtures/svc_app.mettle" "$d/src/main.mettle"
  cp "$here/tests/fixtures/svc_srv.mettle" "$d/tools/srv.mettle"
  {
    printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("app", "0.1.0");\n  mb_bin("app", "src/main.mettle");\n  mb_bin("srv", "tools/srv.mettle");\n'
    for l in "$@"; do printf '  %s\n' "$l"; done
    printf '}\n'
  } >"$d/mbuild.mettle"
}

for mode in ${MBTEST_MODES:-debug release}; do
flag=""
[ $mode = release ] && flag="--release"
echo "== mbuild ($mode)"
sh "$here/tools/mcompile.sh" $flag "$here/src/main.mettle" -o "$S/mbuild-$mode" >"$S/build-$mode.log" 2>&1 || { cat "$S/build-$mode.log"; exit 1; }
MB="$S/mbuild-$mode"
W="$S/$mode"

echo "== $mode: start, ready, run, stop"
proj "$W/ok" "mb_service(\"db\", \"srv $P1 db.pid 300\");" "mb_service_port(\"db\", $P1);" "mb_service(\"cache\", \"srv $P2 'cache.pid'\");" "mb_service_port(\"cache\", $P2);"
cd "$W/ok"
mb run -- $P1 3
check "$mode: in order" [ "$(order)" = "Starting db,Ready db,Starting cache,Ready cache,Running build/linux/debug/app,app,Stopping cache,Stopping db," ]
check "$mode: starting line" has "    Starting db (build/linux/debug/srv $P1 db.pid 300)"
check "$mode: ready line" sh -c 'grep -qE "^       Ready db on :'$P1' \(0\.[3-9]s\)$" "$0/last.out"' "$S"
check "$mode: the app talks to it" has "app got: hi"
check "$mode: the app's exit code" code_is 3
check "$mode: db stopped" gone db.pid
check "$mode: cache stopped" gone cache.pid
check "$mode: output in its log" grep -qxF "srv $P1: listening" .mbuild/logs/db.log
mb run --no-services -- $P1 0
check "$mode: --no-services: none started" hasnt "Starting"
check "$mode: --no-services: the app alone" sh -c 'grep -qF "app: no server" "$0/last.out" && [ "$(cat "$0/last.code")" = 9 ]' "$S"
mb services
check "$mode: services lists them" sh -c '[ "$(cat "$0/last.out")" = "$(printf "db     srv '$P1' db.pid 300   :'$P1'\ncache  srv '$P2' '"'"'cache.pid'"'"'  :'$P2'")" ]' "$S"
mb help run
check "$mode: help run mentions services" sh -c 'grep -qF -- "--no-services" "$0/last.out" && grep -qF "mb_service" "$0/last.out"' "$S"

cd "$W/ok"
build/linux/debug/srv $P2 held.pid >/dev/null 2>&1 &
n=0
while ! { [ -s held.pid ] && port_open $P2; } && [ $n -lt 70 ]; do sleep 0.1; n=$((n + 1)); done
mb run -- $P1 0
kill "$(cat held.pid)"
check "$mode: a port in use is an error" sh -c 'grep -qF "error: service cache: port '$P2' is already in use" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ] && grep -qF "Stopping db" "$0/last.out"' "$S"
check "$mode: ... db stopped" gone db.pid

echo "== $mode: Ctrl-C"
rm -f db.pid
setsid "$MB" run -- $P1 0 5000 >"$S/last.out" 2>&1 &
mpid=$!
n=0
while ! grep -q "app got" "$S/last.out" && [ $n -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
kill -INT "-$mpid"
wait $mpid
echo $? >"$S/last.code"
check "$mode: Ctrl-C ends the app, mbuild exits with its code" code_is 130
check "$mode: Ctrl-C stops the services" sh -c 'grep -qF "Stopping db" "$0/last.out"' "$S"
check "$mode: Ctrl-C leaves nothing running" gone db.pid

echo "== $mode: failures"
proj "$W/slow" "mb_service(\"db\", \"srv $P1 db.pid\");" "mb_service_port(\"db\", $P1);" "mb_service(\"slow\", \"srv $P3 slow.pid 0 quiet\");" "mb_service_port(\"slow\", $P3);" "mb_service_wait(\"slow\", 300);" "mb_service(\"never\", \"srv $P4 never.pid\");"
cd "$W/slow"
mb run -- $P1 0
check "$mode: timeout: error" has "error: service slow: port $P3 not open after 0.3s"
check "$mode: timeout: log tail" sh -c 'grep -qF "  last lines of .mbuild/logs/slow.log:" "$0/last.out" && grep -qxF "    srv '$P3': not listening" "$0/last.out"' "$S"
check "$mode: timeout: exit 1, app not run" sh -c '[ "$(cat "$0/last.code")" = 1 ] && ! grep -q "app got" "$0/last.out" && ! grep -qF "Starting never" "$0/last.out"' "$S"
check "$mode: timeout: the rest stopped" sh -c 'grep -qF "Stopping db" "$0/last.out"' "$S"
check "$mode: timeout: slow stopped" gone slow.pid
check "$mode: timeout: db stopped" gone db.pid

proj "$W/early" "mb_service(\"db\", \"srv $P1 db.pid\");" "mb_service_port(\"db\", $P1);" "mb_service(\"bad\", \"sh -c 'echo boom; exit 3'\");" "mb_service_port(\"bad\", $P3);" "mb_service_env(\"bad\", \"X=1\");"
cd "$W/early"
mb run -- $P1 0
check "$mode: early exit: error" has "error: service bad exited (code 3) before port $P3 opened"
check "$mode: early exit: words shown quoted" has "    Starting bad (sh -c 'echo boom; exit 3')"
check "$mode: early exit: its log" sh -c 'grep -qxF "    boom" "$0/last.out"' "$S"
check "$mode: early exit: exit 1" code_is 1
check "$mode: early exit: db stopped" gone db.pid

proj "$W/missing" "mb_service(\"db\", \"no-such-program-x 1\");"
cd "$W/missing"
mb run -- $P1 0
check "$mode: unknown program" sh -c 'grep -qF "error: service db: cannot find \`no-such-program-x\`" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
proj "$W/quote" "mb_service(\"db\", \"srv 'x\");"
cd "$W/quote"
mb run -- $P1 0
check "$mode: unclosed quote" has "cannot split \`srv 'x\` into words"

echo "== $mode: mb_spawn in a command"
proj "$W/cmd"
cat >>"$W/cmd/mbuild.mettle" <<EOT

fn srv_cmd(port: string, pidfile: string) -> MbCmd* {
  var c: MbCmd* = mb_cmd(mb_out("srv", mb_os(), "debug"));
  mb_cmd_arg(c, port);
  mb_cmd_arg(c, pidfile);
  return c;
}

// up: start two servers, stop one, leave the other running
fn cmd_up(a: MbArgs*) -> int32 {
  var one: MbProc* = mb_spawn(srv_cmd("$P1", "one.pid"));
  var two: MbProc* = mb_spawn(srv_cmd("$P2", "two.pid"));
  if (!mb_wait_port($P1, 5000) || !mb_wait_port($P2, 5000)) {
    mb_fail("no port");
  }
  mb_say("running: {mb_proc_running(one)}");
  mb_stop(one);
  mb_say("after stop: {mb_proc_running(one)}");
  mb_say("closed port: {mb_wait_port($P3, 100)}");
  mb_say("log: " + mb_proc_log(two));
  return 4;
}
EOT
cd "$W/cmd"
mb build
mb up
check "$mode: cmd: running, then stopped" sh -c 'grep -qxF "running: true" "$0/last.out" && grep -qxF "after stop: false" "$0/last.out"' "$S"
check "$mode: cmd: a closed port times out" has "closed port: false"
check "$mode: cmd: the log" sh -c 'grep -qF "log: " "$0/last.out" && grep -qxF "srv '$P2': listening" .mbuild/logs/srv-2.log' "$S"
check "$mode: cmd: its exit code" code_is 4
check "$mode: cmd: the stopped one is gone" gone one.pid
check "$mode: cmd: the one left running is stopped on return" gone two.pid
done

echo "services.sh: $pass passed, $failed failed"
[ $failed = 0 ]
