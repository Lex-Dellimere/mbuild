#!/bin/sh
# r3_build.sh: round-3 acceptance tests of the CLI and orchestration
# (DESIGN.md 17.4 group B) with a real mbuild built from this tree, debug
# and --release, both runs compared by exit code.
#
#   sh tests/e2e/r3_build.sh
#
# Scratch: $MBTEST_TMP (default /tmp/mbuild-test-$USER/r3_build).

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
S="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/r3_build}"
rm -rf "$S"
mkdir -p "$S"
export LC_ALL=C NO_COLOR=1 METTLE
unset MBUILD_COLOR
export MBUILD_HOME="$S/home"
export MBUILD_REGISTRY="$S/reg"

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -30; }
check() { name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$S/last.out" 2>/dev/null)"; fi; }
has() { grep -qF -- "$1" "$S/last.out"; }
hasnt() { ! grep -qF -- "$1" "$S/last.out"; }
code_is() { [ "$(cat "$S/last.code")" = "$1" ]; }
# mb ARGS: runs mbuild in the current directory into last.out / last.code.
mb() { "$MB" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }

for mode in debug release; do
flag=""
[ $mode = release ] && flag="--release"
echo "== mbuild ($mode)"
"$METTLE" --build $flag "$here/src/main.mettle" -o "$S/mbuild-$mode" >"$S/build-$mode.log" 2>&1 || { cat "$S/build-$mode.log"; exit 1; }
if grep -q "warning" "$S/build-$mode.log"; then bad "zero warnings ($mode)" "$(cat "$S/build-$mode.log")"; else ok "zero warnings ($mode)"; fi
MB="$S/mbuild-$mode"
W="$S/$mode"
mkdir -p "$W"

# --- init, run, project commands (13.6, 13.10)
mkdir -p "$W/hello" && cd "$W/hello"
mb init
check "init transcript" sh -c 'grep -qF "Created mbuild.mettle (package \`hello\`)" "$0/last.out" && grep -qF "Created src/main.mettle" "$0/last.out" && grep -qF "Updated .gitignore" "$0/last.out" && grep -qF "next: mbuild run" "$0/last.out"' "$S"
check "gitignore lines" grep -qx "/mbuild.local.mettle" .gitignore
mb run
check "run prints the greeting" has "Hello from hello!"
mb hello bob
check "hello bob" has "hello, bob, from hello"
mb help
check "help lists project commands" sh -c 'grep -qF "project commands (mbuild.mettle):" "$0/last.out" && grep -q "^  hello .*example project command" "$0/last.out"' "$S"
mb helo
check "helo suggests hello" has "did you mean hello?"
cat >> mbuild.mettle <<'EOF'

// build: a command that cannot run
fn cmd_build(a: MbArgs*) -> int32 {
  return 0;
}

// three: exits with 3
fn cmd_three(a: MbArgs*) -> int32 {
  return 3;
}
EOF
mb help
check "cmd_build is shadowed" has "(shadowed by the built-in build; rename cmd_build)"
mb three
check "command exit code" code_is 3

# --- hooks (13.7)
cat >> mbuild.mettle <<'EOF'

fn hook_pre_build() -> int32 {
  mb_write_if_changed("src/version.mettle", "export const APP_VERSION: string = \"" + mb_version() + "\";\n");
  if (mb_exists("fail-hook")) { return 2; }
  return 0;
}
EOF
cat > src/main.mettle <<'EOF'
import "std/io";
import "version";

fn main() -> int32 {
  print("v" + APP_VERSION + "\n");
  return 0;
}
EOF
mb build
check "hook: first build compiles" has "Compiling hello"
mb build
check "hook: second build is Fresh" has "Fresh hello"
touch fail-hook
mb build
check "failing hook stops the build" sh -c 'grep -qF "error: hook_pre_build failed (exit 2) for linux debug" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
mb build --no-hooks
check "--no-hooks skips it" code_is 0
rm -f fail-hook

# --- components (15)
mkdir -p "$W/comp/src/logger" && cd "$W/comp"
cat > mbuild.mettle <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("comp", "0.1.0");
  mb_bin("comp", "src/main.mettle");
  mb_bin("other", "src/other.mettle");
  mb_component("logger", "src/logger", "static", "stdout, quiet");
  mb_profile("release");
  mb_use("logger", "quiet");
}
EOF
printf 'import "std/io";\nexport fn log_line(s: string) { print("stdout: " + s + "\\n"); }\n' > src/logger/stdout.mettle
printf 'export fn log_line(s: string) { }\n' > src/logger/quiet.mettle
printf 'import "logger";\nfn main() -> int32 { log_line("hi"); return 0; }\n' > src/main.mettle
printf 'import "std/io";\nfn main() -> int32 { print("other\\n"); return 0; }\n' > src/other.mettle
mb run comp
check "static logger prints" has "stdout: hi"
mb run comp -r
check "release uses quiet" hasnt "stdout: hi"
mb run comp --use logger=quiet
check "--use logger=quiet" hasnt "stdout: hi"
mb build
mb use logger=quiet
mb build
check "use rebuilds only that bin" sh -c 'grep -qF "Compiling comp (linux, debug)" "$0/last.out" && grep -qF "Fresh other (linux, debug)" "$0/last.out"' "$S"
mb run comp
check "use logger=quiet then run" hasnt "stdout: hi"
mb components
check "components shows mbuild.local.mettle" has "mbuild.local.mettle"

# --- rules (15.8)
mkdir -p "$W/rules/src" "$W/rules/rules" && cd "$W/rules"
cat > mbuild.mettle <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("rules", "0.1.0");
  mb_rule("rules/norec.mettle");
}
EOF
printf 'fn f(n: int32) -> int32 { if (n == 0) { return 0; } return f(n - 1); }\nfn main() -> int32 { return f(3); }\n' > src/main.mettle
cat > rules/norec.mettle <<'EOF'
import "std/rule";

@rule fn no_recursion(p: Program) -> Verdict {
  for f in p.functions {
    if (f.is_recursive && f.name == "f") {
      return verdict_fail(f.site, "no recursion here");
    }
  }
  return verdict_pass();
}
EOF
mb build
check "rule fails the build" sh -c 'grep -qF "R0002" "$0/last.out" && grep -qF "could not compile rules (linux, debug)" "$0/last.out"' "$S"

# --- bin kinds (15.7)
mkdir -p "$W/kinds/src" && cd "$W/kinds"
cat > mbuild.mettle <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("kinds", "0.1.0");
  mb_bin("lib", "src/lib.mettle");
  mb_bin_kind("lib", "shared", "");
  mb_bin("boot", "src/boot.mettle");
  mb_bin_kind("boot", "flat", "x86_64-none");
  mb_for_bin("boot");
  mb_set("image-base", "0x100000");
  mb_profile("release");
  mb_set("crash-report", "false");
}
EOF
printf 'export fn add(a: int32, b: int32) -> int32 { return a + b; }\n' > src/lib.mettle
printf 'fn main() -> int32 { return 7; }\n' > src/boot.mettle
mb build
check "shared bin is an ELF shared object" sh -c 'file build/linux/debug/liblib.so | grep -q "shared object"'
check "flat bin" test -f build/x86_64-none/debug/boot.bin
mb build -r -v lib
check "crash-report = false" has "--no-crash-report"

# --- live (15.4)
mkdir -p "$W/live/src" && cd "$W/live"
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("live", "0.1.0");\n}\n' > mbuild.mettle
cat > src/main.mettle <<'EOF'
import "std/io";
import "std/thread";

fn value() -> int32 { return 1; }

fn main() -> int32 {
  var i: int32 = 0;
  while (i < 60) {
    print("{value()}\n");
    quiesce;
    thread_sleep_ms(100);
    i = i + 1;
  }
  return 0;
}
EOF
( sleep 1.5; sed -i 's/return 1;/return 2;/' src/main.mettle ) &
timeout 8 "$MB" live >"$S/last.out" 2>&1
wait
check "live patches" has "Patch 1"

# --- publish, yank, registry (14.7)
mkdir -p "$W/pkg" && cd "$W/pkg"
"$MB" registry init "$S/reg-$mode" >"$S/last.out" 2>&1
check "registry init" test -f "$S/reg-$mode/registry.toml"
cat > mbuild.mettle <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("strx", "1.0.0");
}
EOF
printf 'export fn strx_a() -> int32 { return 1; }\nexport fn strx_b() -> int32 { return 2; }\n' > strx.mettle
mb publish --to "$S/reg-$mode"
check "publish without init.rules" has "strx cannot be published without init.rules (mbuild init --package writes one)"
rm mbuild.mettle
mb init strx --package
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("strx", "1.0.0");\n}\n' > mbuild.mettle
rm -f src/main.mettle
printf '# strx\n# >>> mbuild: AGENT.rules of this project'"'"'s dependencies (generated)\n# x\n# <<< mbuild\n' >> AGENT.rules
mb publish --to "$S/reg-$mode"
check "publish transcript" sh -c 'grep -qF "Packaging strx v1.0.0" "$0/last.out" && grep -qF "Published strx v1.0.0 to" "$0/last.out" && grep -qF "next: upload" "$0/last.out"' "$S"
mkdir -p "$S/unpack-$mode" && tar -xzf "$S/reg-$mode/pkg/strx/strx-v1.0.0.tar.gz" -C "$S/unpack-$mode"
check "published AGENT.rules has no block" sh -c '! grep -q ">>> mbuild" "$0/unpack-'$mode'/AGENT.rules"' "$S"
sed -i 's/1.0.0/1.1.0/' mbuild.mettle
printf 'export fn strx_a() -> int32 { return 1; }\n' > strx.mettle
mb publish --to "$S/reg-$mode"
check "removed export refused" has "strx_b"
mb publish --to "$S/reg-$mode" --allow-breaking
check "--allow-breaking publishes" has "Published strx v1.1.0"
mb yank strx@v1.1.0 --to "$S/reg-$mode"
check "yank" grep -q "v1.1.0 .*yanked" "$S/reg-$mode/index/strx"
mkdir -p "$W/user/src" && cd "$W/user"
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("user", "0.1.0");\n  mb_dep("strx", "v1.0.0");\n}\n' > mbuild.mettle
printf 'import "std/io";\nimport "strx/strx";\nfn main() -> int32 { print("a={strx_a()}\\n"); return 0; }\n' > src/main.mettle
MBUILD_REGISTRY="$S/reg-$mode" "$MB" run >"$S/last.out" 2>&1
check "a user of the published package builds and runs" has "a=1"
MBUILD_REGISTRY="$S/reg-$mode" "$MB" outdated >"$S/last.out" 2>&1
check "yanked version not offered" hasnt "v1.1.0"

# --- mbuild.toml is gone
mkdir -p "$W/old" && cd "$W/old" && printf '[package]\nname = "old"\n' > mbuild.toml
mb build
check "mbuild.toml refused" has "error: mbuild.toml is no longer read; write mbuild.mettle (mbuild init)"
done

echo
echo "$pass passed, $failed failed"
[ $failed = 0 ]
