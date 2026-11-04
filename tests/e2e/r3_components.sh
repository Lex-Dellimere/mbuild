#!/bin/sh
# r3_components.sh: components and runtime (DESIGN.md 15, 17.4 group K)
# through tests/unit/components_driver.mettle, built debug and --release
# with zero warnings; both builds run every check and must agree. Then the
# `mbuild components` table and a `mettle live` switch through cmp_cmd_use.
#
#   sh tests/e2e/r3_components.sh
#
# Scratch: $MBTEST_TMP (default /tmp/mbuild-test-$USER/r3_components).
# Compiler: $METTLE (default ../Mettle/bin/mettle next to the repository).

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
export METTLE
T="${MBTEST_TMP:-/tmp/mbuild-test-$USER/r3_components}"
W="$T/work"
export MBUILD_HOME="$T/home"
export NO_COLOR=1
rm -rf "$T"
mkdir -p "$W" "$MBUILD_HOME"

pass=0
failn=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /'; }
expect_line() {
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else bad "$1 (wanted line: $3)" "$2"; fi
}

# put FILE: stdin into $W/FILE
put() { mkdir -p "$(dirname "$W/$1")"; cat > "$W/$1"; }

put static/mbuild.toml <<'EOF'
[package]
name = "app"
[component.logger]
dir = "src/logger"
impls = ["stdout", "quiet", "file"]
windows = "quiet"
[profile.release]
components = ["logger=quiet"]
EOF
put static/src/logger/stdout.mettle <<'EOF'
import "std/io";

export fn log_line(s: string) -> int32 {
  println("stdout: {s}");
  return 1;
}
EOF
put static/src/logger/quiet.mettle <<'EOF'
export fn log_line(s: string) -> int32 {
  return 0;
}
EOF
put static/src/logger/file.mettle <<'EOF'
export fn log_open(path: string) -> int32 {
  return 0;
}
EOF
put static/src/main.mettle <<'EOF'
import "logger";

fn main() -> int32 {
  log_line("hi");
  return 0;
}
EOF
put static/src/live.mettle <<'EOF'
import "logger";

extern fn usleep(us: uint32) -> int32;

fn main() -> int32 {
  var i: int32 = 0;
  while (i < 40) {
    quiesce;
    log_line("tick");
    usleep(200000);
    i = i + 1;
  }
  return 0;
}
EOF

for d in dyn dynbad; do
put $d/mbuild.toml <<'EOF'
[package]
name = "app"
[component.renderer]
dir = "src/renderer"
mode = "dyn"
impls = ["ascii", "fancy"]
EOF
put $d/src/renderer/renderer.mettle <<'EOF'
import "std/meta";

@dyn export trait Renderer {
  fn cost(self: Self) -> int32;
}
EOF
put $d/src/renderer/ascii.mettle <<'EOF'
import "renderer";

export struct Ascii {
  w: int32;
}

impl Renderer for Ascii {
  fn cost(self: Self) -> int32 { return self.w; }
}

export fn renderer_ascii_new() -> Renderer__dyn {
  var a: Ascii* = new Ascii;
  a->w = 105;
  return Renderer__from_Ascii(a);
}
EOF
sed 's/Ascii/Fancy/g; s/ascii/fancy/g; s/105/5000/' "$W/$d/src/renderer/ascii.mettle" > "$W/$d/src/renderer/fancy.mettle"
put $d/src/main.mettle <<'EOF'
import "std/io";
import "renderer";

extern fn strlen(s: cstring) -> int64;

fn main(argc: int32, argv: cstring*) -> int32 {
  var name: string = RENDERER_IMPL;
  if (argc > 1) {
    name.chars = (uint8*)argv[1];
    name.length = (uint64)strlen(argv[1]);
  }
  var r: Renderer__dyn = renderer_new(name);
  println("{name}: {r.cost()}");
  return 0;
}
EOF
done
sed -i 's/^export struct Fancy/struct Fancy/' "$W/dynbad/src/renderer/fancy.mettle"

for d in swap swapbad; do
put $d/mbuild.toml <<'EOF'
[package]
name = "app"
[component.policy]
dir = "src/policy"
mode = "swap"
impls = ["gentle", "harsh"]
EOF
done
put swap/src/policy/gentle.mettle <<'EOF'
@swappable export fn policy_score(n: int32) -> int32 {
  return n + 1;
}
EOF
put swap/src/policy/harsh.mettle <<'EOF'
@swappable export fn policy_score(n: int32) -> int32 {
  return n * 10;
}
EOF
put swap/src/main.mettle <<'EOF'
import "std/io";
import "policy";

fn main() -> int32 {
  var a: int32 = policy_score(5);
  println("{a}");
  policy_stage("harsh");
  var b: int32 = policy_score(5);
  println("{b}");
  quiesce;
  var c: int32 = policy_score(5);
  println("{c}");
  return 0;
}
EOF
put swapbad/src/policy/types.mettle <<'EOF'
export struct LogMsg {
  level: int32;
}
EOF
for i in gentle harsh; do
put swapbad/src/policy/$i.mettle <<'EOF'
import "types";

@swappable export fn policy_rate(m: LogMsg*) -> int32 {
  return m->level;
}
EOF
done
cp "$W/swap/src/main.mettle" "$W/swapbad/src/main.mettle"

put rules/mbuild.toml <<'EOF'
[package]
name = "app"
[rules]
files = ["rules/norec.mettle"]
EOF
put rules/rules/norec.mettle <<'EOF'
import "std/rule";

@rule fn no_recursion(p: Program) -> Verdict {
  for f in p.functions {
    if (f.name == "depth" && f.is_recursive) {
      return verdict_fail(f.site, "this program forbids recursion");
    }
  }
  return verdict_pass();
}
EOF
put rules/src/util.mettle <<'EOF'
export fn depth(n: int32) -> int32 {
  if (n <= 0) {
    return 0;
  }
  return 1 + depth(n - 1);
}
EOF
put rules/src/main.mettle <<'EOF'
import "util";

fn main() -> int32 {
  return depth(3) - 3;
}
EOF

put comps/mbuild.toml <<'EOF'
[package]
name = "comps"
[component.kv]
dir = "src/kv"
impls = ["mem", "file"]
EOF
for i in mem file; do
put comps/src/kv/$i.mettle <<'EOF'
export fn kv_get(k: string) -> string {
  return k;
}
EOF
done
put clash/mbuild.toml <<'EOF'
[package]
name = "clash"
[component.logger]
dir = "src/logger"
impls = ["x"]
EOF
put clash/src/logger/x.mettle <<'EOF'
export fn log_line(s: string) -> int32 {
  return 0;
}
EOF
put kv/mbuild.toml <<'EOF'
[package]
name = "kv"
EOF

for d in chk chkbad; do
put $d/mbuild.toml <<'EOF'
[package]
name = "chk"
[component.kv]
dir = "src/kv"
impls = ["mem", "disk"]
EOF
cp -r "$W/comps/src" "$W/$d/src"
mv "$W/$d/src/kv/file.mettle" "$W/$d/src/kv/disk.mettle"
done
put chkbad/src/kv/disk.mettle <<'EOF'
export fn kv_get(k: string) -> string {
  return 5;
}
EOF

echo "== building the driver"
D="$T/components_driver"
for mode in debug release; do
  flag=""
  [ "$mode" = release ] && flag="--release"
  out=$("$METTLE" --build $flag "$here/tests/unit/components_driver.mettle" -o "$D-$mode" 2>&1)
  code=$?
  if [ $code -ne 0 ]; then bad "driver builds ($mode)" "$out"; echo "$pass passed, $failn failed"; exit 1; fi
  if printf '%s\n' "$out" | grep -q 'warning'; then bad "driver builds without warnings ($mode)" "$out"; else ok "driver builds without warnings ($mode)"; fi
done

echo "== driver checks"
dbg=$("$D-debug" "$W" all 2>/dev/null); dcode=$?
rel=$("$D-release" "$W" all 2>/dev/null); rcode=$?
printf '%s\n' "$dbg" | grep -E '^(ok|FAIL) ' | sed 's/^ok /PASS /'
[ $dcode -eq 0 ] && ok "driver passes (debug)" || bad "driver passes (debug)" "$(printf '%s\n' "$dbg" | grep -v '^ok ')"
[ $rcode -eq 0 ] && ok "driver passes (release)" || bad "driver passes (release)" "$(printf '%s\n' "$rel" | grep -v '^ok ')"
[ "$dbg" = "$rel" ] && ok "debug and release agree" || bad "debug and release agree" "$(printf '%s\n' "$dbg" > "$T/d.txt"; printf '%s\n' "$rel" > "$T/r.txt"; diff "$T/d.txt" "$T/r.txt")"

echo "== mbuild components"
"$D-debug" "$W" use logger=quiet > /dev/null 2>&1
tab=$("$D-debug" "$W" components 2>&1)
expect_line "components header" "$tab" "COMPONENT  MODE    IMPLS              SELECTED (linux, debug)  FROM"
expect_line "components row" "$tab" "logger     static  stdout quiet file  quiet                    mbuild.local.toml"
"$D-debug" "$W" use logger > /dev/null 2>&1
tab=$("$D-debug" "$W" components 2>&1)
expect_line "components row after use NAME" "$tab" "logger     static  stdout quiet file  stdout                   default"
use_out=$("$D-debug" "$W" use logger=quiet 2>&1)
expect_line "use prints the choice" "$use_out" "       Using logger = quiet (mbuild.local.toml)"
"$D-debug" "$W" use logger > /dev/null 2>&1

echo "== mettle live, then use logger=quiet"
prep=$("$D-debug" "$W" prepare 2>&1) || { bad "prepare live" "$prep"; }
gen=$(printf '%s\n' "$prep" | sed -n 1p)
entry=$(printf '%s\n' "$prep" | sed -n 2p)
( cd "$W/static" && timeout 8 "$METTLE" live "$entry" -I "$gen" -o "$T/live-prog" > "$T/live.out" 2>&1 ) &
lp=$!
sleep 1.5
"$D-debug" "$W" use logger=quiet > "$T/use.out" 2>&1
wait $lp
live=$(cat "$T/live.out")
if printf '%s\n' "$live" | grep -q '^stdout: tick'; then ok "live runs the stdout impl"; else bad "live runs the stdout impl" "$live"; fi
after=$(printf '%s\n' "$live" | sed -n '/Patch/,$p' | grep -c '^stdout: tick')
if printf '%s\n' "$live" | grep -q 'Patch' && [ "$after" -eq 0 ]; then ok "live switches to quiet"; else bad "live switches to quiet" "$live"; fi
"$D-debug" "$W" use logger > /dev/null 2>&1

echo "$pass passed, $failn failed"
[ $failn -eq 0 ]
