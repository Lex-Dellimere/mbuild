#!/bin/sh
# config.sh: loading mbuild.mettle, project commands, hooks and edits (tests/unit/config_test.mettle).
#   METTLE=dev-compiler sh tests/e2e/config.sh   (scratch: $MBTEST_TMP)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
T="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-user}/config}"
rm -rf "$T"
mkdir -p "$T"
export MBUILD_HOME="$T/home"
export MBUILD_METTLE_LINUX="$METTLE"
unset MBUILD_DEPTH MBUILD_CHAIN

pass=0
failn=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /'; }
expect_line() {
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else bad "$1 (wanted line: $3)" "$2"; fi
}
expect_has() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (wanted: $3)" "$2"; fi
}
expect_no() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then bad "$1 (unwanted: $3)" "$2"; else ok "$1"; fi
}
expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got:
$2
want:
$3"; fi
}

# unit NAME: tests/unit/NAME.mettle built debug and --release, both runs agree
unit() { if out=$(METTLE="$METTLE" TMPDIR="$T" sh "$here/tools/mcheck.sh" "$here/tests/unit/$1.mettle" --run 2>&1); then ok "$1 ($(printf '%s\n' "$out" | sed -n 's/^\[run\] ok (.*: \(.*\))$/\1/p'))"; else bad "$1" "$out"; fi; }

echo "== unit tests"
unit toml_test
unit manifest_test
unit mbfile_test

echo "== building"
for mode in debug release; do
  flag=""; [ $mode = release ] && flag="--release"
  log=$("$METTLE" --build $flag "$here/tests/unit/config_test.mettle" -o "$T/config_driver.$mode" 2>&1) || { printf '%s\n' "$log"; echo "config_driver ($mode) does not build"; exit 1; }
  expect_no "config_driver ($mode): no warnings" "$log" "warning"
  log=$("$METTLE" --build $flag "$here/tests/unit/mbfile_test.mettle" -o "$T/mbfile_test.$mode" 2>&1) || { printf '%s\n' "$log"; echo "mbfile_test ($mode) does not build"; exit 1; }
  expect_no "mbfile_test ($mode): no warnings" "$log" "warning"
  out=$("$T/mbfile_test.$mode"); code=$?
  if [ $code = 0 ]; then ok "mbfile_test ($mode): $(printf '%s\n' "$out" | tail -1)"; else bad "mbfile_test ($mode) exit $code" "$(printf '%s\n' "$out" | grep -A2 '^FAIL')"; fi
done

# Fresh copy of a project per build so the two runs cannot share caches.
viewer() {
  rm -rf "$1"; mkdir -p "$1/src/version.mettle"
  cp "$here/tests/unit/mbfile_viewer.txt" "$1/mbuild.mettle"
}

cat > "$T/expected.toml" <<'EOF'
[package]
name = "viewer"
version = "0.3.0"
description = "image viewer"
[build]
targets = ["linux", "windows"]
[dependencies]
strutil = "v1.1.0"
auth = { version = "v2.0.0", registry = "corp" }
widgets = { path = "../widgets" }
[registry.corp]
url = "https://pkgs.example.com/mettle"
[component.renderer]
dir = "src/renderer"
mode = "static"
impls = ["soft", "gl"]
windows = "soft"
[rules]
files = ["rules/no_alloc_in_draw.mettle"]
[profile.release]
optimize = "full"
crash-report = false
components = ["renderer=gl"]
[profile.release.windows]
subsystem = "windows"
[profile.debug]
safe = true
EOF
printf '#!/bin/sh\necho "stub got: $*"\n' > "$T/stub.sh"
chmod +x "$T/stub.sh"

run_cases() {
  mode=$1
  D="$T/config_driver.$mode"
  P="$T/run.$mode"
  mkdir -p "$P"

  echo "== $mode: the 13.4 example"
  viewer "$P/viewer"
  cd "$P/viewer"
  want=$("$D" dumptoml "$T/expected.toml")
  got=$("$D" -v load 2>"$P/err1"); code=$?
  expect_eq "$mode: cfg_load equals 13.5's manifest" "$code
$got" "0
$want"
  expect_has "$mode: first load compiles" "$(cat "$P/err1")" "driver.mettle -o"
  expect_eq "$mode: emitted TOML is 13.5's" "$("$D" text)" "$(cat "$T/expected.toml")"
  "$D" -v load >/dev/null 2>"$P/err2"
  expect_no "$mode: second load compiles nothing" "$(cat "$P/err2")" "driver.mettle -o"
  expect_no "$mode: second load runs nothing" "$(cat "$P/err2")" "driver config"
  expect_eq "$mode: info" "$("$D" info)" "command install: build a release and copy it into a bin directory (default ~/.local/bin)
hooks pre_build"
  rm -rf src/version.mettle
  out=$("$D" hook pre_build)
  expect_eq "$mode: pre_build hook exit" "$out" "hook exit 0"
  expect_eq "$mode: hook output" "$(cat src/version.mettle)" 'export const VIEWER_VERSION: string = "0.3.0";'

  echo "== $mode: an imported file is in the cache key"
  mkdir -p "$P/imp" && cd "$P/imp"
  printf 'export fn imp_version() -> string {\n  return "1.0.0";\n}\n' > helpers.mettle
  printf 'import "mbuild/api";\nimport "helpers.mettle";\n\nfn project() {\n  mb_package("imp", imp_version());\n}\n' > mbuild.mettle
  expect_line "$mode: helper value" "$("$D" load)" "package imp 1.0.0"
  printf 'export fn imp_version() -> string {\n  return "2.0.0";\n}\n' > helpers.mettle
  out=$("$D" -v load 2>&1)
  expect_has "$mode: edited import recompiles" "$out" "driver.mettle -o"
  expect_line "$mode: new value" "$out" "package imp 2.0.0"

  echo "== $mode: errors"
  mkdir -p "$P/typo" && cd "$P/typo"
  printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("t", 1);\n}\n' > mbuild.mettle
  out=$("$D" load 2>&1); code=$?
  expect_has "$mode: type error: compiler output" "$out" "error["
  expect_has "$mode: type error: our line" "$out" "error: mbuild.mettle does not compile"
  expect_eq "$mode: type error: exit 1" "$code" "1"

  mkdir -p "$P/env" && cd "$P/env"
  printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("e", mb_env("HOME"));\n}\n' > mbuild.mettle
  out=$("$D" load 2>&1); code=$?
  expect_line "$mode: mb_env in project() refused" "$out" "error: mbuild.mettle: mb_env cannot be used in fn project() (the project description must be the same on every machine; use mbuild.local.mettle, a command, or a hook)"
  expect_eq "$mode: refusal exit 3" "$code" "3"

  mkdir -p "$P/fast" && cd "$P/fast"
  printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("f", "0.1.0");\n  mb_profile("release");\n  mb_set("optimize", "fast");\n}\n' > mbuild.mettle
  out=$("$D" load 2>&1); code=$?
  expect_has "$mode: bad setting at the mb_set line" "$out" 'error: mbuild.mettle:6: optimize = "fast" is not one of'
  expect_eq "$mode: bad setting exit 1" "$code" "1"

  mkdir -p "$P/legacy" && cd "$P/legacy"
  printf '[package]\nname = "old"\n' > mbuild.toml
  out=$("$D" load 2>&1); code=$?
  expect_line "$mode: mbuild.toml refused" "$out" "error: mbuild.toml is no longer read; write mbuild.mettle (mbuild init)"

  mkdir -p "$P/nomain" && cd "$P/nomain"
  printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("m", "0.1.0");\n}\n\nfn main() -> int32 {\n  return 0;\n}\n' > mbuild.mettle
  out=$("$D" load 2>&1)
  expect_has "$mode: fn main refused" "$out" "error: mbuild.mettle:7: mbuild.mettle cannot define fn main"

  mkdir -p "$P/iroot/src" && cd "$P/iroot"
  printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("iroot", "0.1.0");\n  mb_import_root("src");\n}\n' > mbuild.mettle
  "$D" load >/dev/null
  expect_eq "$mode: mb_import_root emits" "$("$D" text | sed -n '/^import-root/p')" 'import-root = "src"'
  sed -i 's|mb_import_root("src")|mb_import_root("lib")|' mbuild.mettle
  out=$("$D" load 2>&1)
  expect_line "$mode: import root must exist" "$out" 'error: mbuild.mettle:5: mb_import_root("lib"): lib is not a directory'
  sed -i 's|mb_import_root("lib")|mb_import_root("../src")|' mbuild.mettle
  out=$("$D" load 2>&1)
  expect_line "$mode: import root inside the package" "$out" 'error: mbuild.mettle:5: mb_import_root("../src"): the import root is a directory inside the package, relative to it (e.g. "src")'

  echo "== $mode: commands"
  mkdir -p "$P/hello" && cd "$P/hello"
  "$D" inittext hello
  expect_eq "$mode: init text command" "$("$D" hello bob)" "hello, bob, from hello"
  cat >> mbuild.mettle <<'EOF'

// callver: runs mbuild version
fn cmd_callver(a: MbArgs*) -> int32 {
  return mb_mbuild("version");
}

fn cmd_nest(a: MbArgs*) -> int32 {
  return mb_mbuild("nest");
}

fn cmd_three(a: MbArgs*) -> int32 {
  return 3;
}

fn hook_post_build() -> int32 {
  mb_say("post " + mb_target() + " " + mb_profile_name() + " [" + mb_bins() + "]");
  return 2;
}
EOF
  expect_eq "$mode: mb_mbuild reaches MBUILD_EXE" "$("$D" callver)" "config_driver as mbuild: version"
  "$D" load >/dev/null
  out=$(MBUILD_EXE="$T/stub.sh" .mbuild/config/driver cmd callver)
  expect_eq "$mode: mb_mbuild with a stub MBUILD_EXE" "$out" "stub got: version"
  out=$("$D" nest 2>&1); code=$?
  expect_has "$mode: nesting past 8" "$out" "error: mbuild commands nest more than 8 deep (cmd_nest -> cmd_nest -> cmd_nest -> cmd_nest -> cmd_nest -> cmd_nest -> cmd_nest -> cmd_nest -> cmd_nest)"
  expect_eq "$mode: nesting exit" "$code" "1"
  "$D" three; expect_eq "$mode: command exit code" "$?" "3"
  out=$("$D" hook post_build 2>&1); code=$?
  expect_line "$mode: hook env" "$out" "post linux debug [app]"
  expect_line "$mode: failing hook message" "$out" "error: hook_post_build failed (exit 2) for linux debug"
  expect_eq "$mode: failing hook exit" "$code" "2"
  out=$("$D" hook pre_build); expect_eq "$mode: absent hook is 0" "$out" "hook exit 0"
  out=$("$D" nosuch 2>&1); expect_has "$mode: unknown command" "$out" "error: no command 'nosuch'"

  echo "== $mode: edits"
  cd "$P/viewer"
  out=$("$D" setdep strutil v1.2.0 2>&1)
  expect_line "$mode: set dep status" "$out" '    Updating mbuild.mettle: mb_dep("strutil", "v1.2.0")'
  expect_line "$mode: set dep reloaded" "$out" "dep strutil version=v1.2.0 path= registry="
  expect_line "$mode: next load sees it" "$("$D" load)" "dep strutil version=v1.2.0 path= registry="
  out=$("$D" setdep json v1.0.0 2>&1)
  expect_line "$mode: add dep status" "$out" '      Adding mbuild.mettle: mb_dep("json", "v1.0.0")'
  out=$("$D" removedep widgets 2>&1)
  expect_line "$mode: remove dep status" "$out" '    Removing mbuild.mettle: mb_dep_path("widgets", "../widgets")'
  expect_no "$mode: removed" "$out" "dep widgets"
  out=$("$D" --locked setdep strutil v1.3.0 2>&1); code=$?
  expect_has "$mode: --locked refuses" "$out" "--locked forbids it"
  mkdir -p "$P/computed" && cd "$P/computed"
  printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("c", "0.1.0");\n  var n: string = "strutil";\n  mb_dep(n, "v1");\n}\n' > mbuild.mettle
  out=$("$D" setdep strutil v1.2.0 2>&1)
  expect_has "$mode: uneditable" "$out" "error: mbuild.mettle:6 declares strutil in a way mbuild cannot edit"
  expect_has "$mode: uneditable help" "$out" 'help: change it to: mb_dep("strutil", "v1.2.0");'

  echo "== $mode: path packages"
  mkdir -p "$P/widgets" "$P/app"
  printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("widgets", "0.2.0");\n}\n\nfn cmd_x(a: MbArgs*) -> int32 {\n  return 0;\n}\n' > "$P/widgets/mbuild.mettle"
  cd "$P/app"
  out=$("$D" loaddir "$P/widgets" widgets)
  expect_line "$mode: path package loads" "$out" "package widgets 0.2.0"
  drv=$(cat .mbuild/config/path/widgets/driver.mettle)
  expect_no "$mode: path package driver has no cmd branch" "$drv" '"cmd"'
  expect_eq "$mode: no mbuild.mettle -> none" "$("$D" loaddir "$P" none)" "no manifest"

  echo "== $mode: mbuild.local.mettle"
  cd "$P/viewer"
  cat > mbuild.local.mettle <<'EOF'
import "mbuild/api";

fn local() {
  mb_use("renderer", "soft");
  mb_replace_path("strutil", "../strutil");
  mb_profile("release");
  mb_set("native-heap", "true");
}
EOF
  out=$("$D" -v load 2>&1)
  expect_has "$mode: local file recompiles" "$out" "driver.mettle -o"
  expect_line "$mode: local components" "$out" "local components renderer=soft"
  expect_line "$mode: local replace" "$out" "replace strutil path=../strutil version="
  expect_has "$mode: local profile setting" "$out" "settings release linux: --release --no-crash-report --native-heap"
  out=$("$D" setcall mbuild.local.mettle mb_use renderer gl)
  expect_line "$mode: setcall rewrites" "$(cat mbuild.local.mettle)" '  mb_use("renderer", "gl");'
  "$D" setcall mbuild.local.mettle mb_tool cc clang >/dev/null
  expect_line "$mode: setcall adds after the brace" "$(sed -n 4p mbuild.local.mettle)" '  mb_tool("cc", "clang");'
  "$D" removecall mbuild.local.mettle mb_replace_path strutil >/dev/null
  out=$("$D" load 2>&1)
  expect_line "$mode: edited local file reloads" "$out" "local components renderer=gl"
  expect_no "$mode: removed replacement" "$out" "replace strutil"
  rm -f "$P/new.local"
  "$D" setcall "$P/new.local" mb_use logger quiet >/dev/null
  expect_eq "$mode: setcall creates the file" "$(cat "$P/new.local")" 'import "mbuild/api";

fn local() {
  mb_use("logger", "quiet");
}'
  printf 'import "mbuild/api";\n\nfn local() {\n  mb_set("safe", "true");\n}\n' > mbuild.local.mettle
  out=$("$D" load 2>&1)
  expect_line "$mode: API error in fn local()" "$out" "error: mbuild.local.mettle: mb_set needs mb_profile(NAME) or mb_for_bin(NAME) before it"
  printf 'import "mbuild/api";\n\nfn local() {\n  mb_profile("release");\n  mb_set("optimize", "fast");\n}\n' > mbuild.local.mettle
  out=$("$D" load 2>&1)
  expect_has "$mode: local setting error at its line" "$out" 'error: mbuild.local.mettle:5: optimize = "fast" is not one of'
  rm -f mbuild.local.mettle

  echo "== $mode: cfg_build_driver"
  out=$("$D" -v build-driver "$P/bd" 2>&1)
  expect_line "$mode: build-driver" "$out" "exe driver"
  expect_eq "$mode: the program runs" "$("$P/bd/driver")" "built by cfg_build_driver"
  out=$("$D" -v build-driver "$P/bd" 2>&1)
  expect_no "$mode: unchanged: no compile" "$out" "driver.mettle -o"
  cd "$T"
}

run_cases debug > "$T/debug.log" 2>&1
run_cases release > "$T/release.log" 2>&1
cat "$T/debug.log"
pass=$(grep -c '^PASS' "$T/debug.log" "$T/release.log" | awk -F: '{s+=$2} END {print s}')
failn=$(grep -c '^FAIL' "$T/debug.log" "$T/release.log" | awk -F: '{s+=$2} END {print s}')
grep '^FAIL' "$T/release.log" | sed 's/^/release: /'
norm() { sed -e "s|$T/run.$1|RUN|g" -e "s/^\([A-Z=]*\) $1: /\1 /" "$T/$1.log"; }
if [ "$(norm debug)" = "$(norm release)" ]; then
  echo "PASS debug and release outputs match"
else
  failn=$((failn + 1))
  echo "FAIL debug and release outputs differ"
  norm debug > "$T/debug.norm"; norm release > "$T/release.norm"
  diff "$T/debug.norm" "$T/release.norm" | head -20
fi
echo
echo "config: $pass passed, $failn failed"
[ "$failn" = 0 ]
