#!/bin/sh
# r2_build.sh: round-2 acceptance tests of src/build.mettle, src/main.mettle
# (DESIGN.md 12.21 group B) with a real mbuild built from this tree (head).
#
#   sh tests/r2_build.sh            (E2E_NO_WINE=1 skips the wine checks)
#
# Scratch: /tmp/opencode/r2-B (MBUILD_HOME inside it; toolchains -> ~/.mbuild/toolchains).

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
HEAD="${METTLE_HEAD:-$here/../Mettle/bin/mettle}"
L017="${METTLE_L017:-$HOME/.mbuild/toolchains/v0.17.0/linux/bin/mettle}"
W017="${METTLE_W017:-$HOME/.mbuild/toolchains/v0.17.0/windows/mettle.exe}"
S=/tmp/opencode/r2-B
rm -rf "$S"
mkdir -p "$S"
export LC_ALL=C NO_COLOR=1 WINEDEBUG=-all
unset MBUILD_COLOR

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -30; }
check() { name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$S/last.out" 2>/dev/null)"; fi; }
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
code_is() { [ "$(cat "$S/last.code")" = "$1" ]; }
same() { cmp -s "$1" "$2"; }

echo "== building mbuild"
"$HEAD" --build "$here/src/main.mettle" -o "$S/mbuild" >"$S/build.log" 2>&1 || { cat "$S/build.log"; exit 1; }
MB="$S/mbuild"

F="$S/fx"
"$here/tests/fixtures/make-fixtures.sh" "$F" >/dev/null
sh "$here/tests/fixtures/make-fixtures-r2.sh" "$F" >/dev/null
G="$F/gitbase/github.com/demo"
export MBUILD_HOME="$S/home"
mkdir -p "$MBUILD_HOME"
ln -s "$HOME/.mbuild/toolchains" "$MBUILD_HOME/toolchains"
export MBUILD_GIT_BASE="$F/gitbase"
export MBUILD_METTLE_LINUX="$HEAD"
export MBUILD_METTLE_WINDOWS="$W017"

mb() { (cd "$1" && shift && "$MB" "$@") >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }
# proj DIR then dependency lines on stdin; main.mettle from $MAIN
proj() {
  rm -rf "$1"; mkdir -p "$1/src"
  { printf '[package]\nname = "%s"\n\n[dependencies]\n' "$(basename "$1")"; cat; } >"$1/mbuild.toml"
  printf '%s\n' "${MAIN:-fn main() -> int32 { return 0; \}}" >"$1/src/main.mettle"
}

echo "== settings in compiles"
P="$S/set"
proj "$P" </dev/null
mb "$P" -v build
check "debug build passes -s" has "$S/last.out" " -s"
mb "$P" -v build -r
check "release passes --release" has "$S/last.out" "--release"
not_s() { ! grep -q -- "--build.* -s\( \|$\)" "$S/last.out"; }
check "release has no -s" not_s
mb "$P" -v build --set safe=true
check "--set safe=true: --safe in argv" has "$S/last.out" "--safe"
check "--set safe=true: rebuilt" has "$S/last.out" "Compiling set (linux, debug)"
mb "$P" -v build --set safe=true
check "--set again: Fresh" has "$S/last.out" "Fresh set (linux, debug)"
mb "$P" -v build --flag=--explain -r
check "--flag after typed flags" grep -q -- "--release --explain" "$S/last.out"
mb "$P" -v build --flag --explain -r --force
check "--flag ARG form" grep -q -- "--release --explain" "$S/last.out"

echo "== check-overflow needs a newer compiler"
printf '\n[profile.release]\ncheck-overflow = true\n' >>"$P/mbuild.toml"
(cd "$P" && MBUILD_METTLE_LINUX="$L017" "$MB" -v build -r) >"$S/last.out" 2>&1; echo $? >"$S/last.code"
check "v0.17.0: exit 1" code_is 1
check "v0.17.0: 12.12 error" has "$S/last.out" "error: [profile.release] check-overflow = true needs a Mettle compiler that has --check-overflow; the linux compiler ($(readlink -f "$L017"), v0.17.0) does not"
check "v0.17.0: help" has "$S/last.out" "help: use a newer compiler (\`mbuild toolchain use latest\`), or set check-overflow = false"
mb "$P" build -r
check "head: builds" code_is 0
(cd "$P" && MBUILD_METTLE_LINUX="$L017" "$MB" -v build -r) >"$S/last.out" 2>&1; echo $? >"$S/last.code"
check "second v0.17.0 run: still refused" code_is 1
check "second v0.17.0 run: no probe" hasnt "$S/last.out" "probing"
printf '\n[build]\nflags = ["--bogus-flag"]\n' >>"$P/mbuild.toml"
sed -i 's/check-overflow = true/check-overflow = false/' "$P/mbuild.toml"
mb "$P" build
check "raw flag rejected" has "$S/last.out" "error: flags: the linux compiler does not accept --bogus-flag (mbuild.toml:"

echo "== mbuild profiles"
P="$S/prof"
proj "$P" </dev/null
printf '\n[profile.fast]\ninherits = "release"\ncheck-overflow = true\n' >>"$P/mbuild.toml"
mb "$P" profiles
tr -s ' ' <"$S/last.out" >"$S/prof.txt"; cp "$S/prof.txt" "$S/last.out"
check "profiles: debug row" has "$S/last.out" "debug stack-trace -> -s"
check "profiles: release row" has "$S/last.out" "release optimize=full -> --release"
check "profiles: fast row" has "$S/last.out" "fast inherits release; check-overflow (mbuild.toml:8) -> --release --check-overflow"

echo "== update"
P="$S/upd"
MAIN='import "std/io";
import "github.com/demo/apilib/apilib";
fn main() -> int32 {
  var m: int32 = al_mul(2, 3);
  println("{al_add(1, 2)} {m}");
  return 0;
}' proj "$P" <<'EOF'
"github.com/demo/apilib" = "v1.0.0"
EOF
mb "$P" build
check "update project builds" code_is 0
mb "$P" update
check "update: exit 0" code_is 0
check "update: Updated line" has "$S/last.out" "Updated github.com/demo/apilib v1.0.0 -> v1.1.0"
check "update: Held line" has "$S/last.out" "Held github.com/demo/apilib v1.2.0: src/main.mettle:4: Undefined function 'al_mul'"
check "update: Summary" has "$S/last.out" "Summary 1 updated, 1 held back"
check "update: mbuild.toml" grep -q '"github.com/demo/apilib" = "v1.1.0"' "$P/mbuild.toml"
check "update: checkout at v1.1.0" [ "$(head -1 "$P/.mbuild/deps/github.com/demo/apilib/.mbuild-commit")" = "$(git -C "$G/apilib" rev-parse 'v1.1.0^{commit}')" ]

echo "== update, two modules, one bad"
P="$S/upd2"
MAIN='import "std/io";
import "github.com/demo/apilib/apilib";
import "github.com/demo/zero/zero";
fn main() -> int32 {
  var m: int32 = al_mul(2, 3);
  println("{al_add(1, 2)} {m} {z_one()}");
  return 0;
}' proj "$P" <<'EOF'
"github.com/demo/apilib" = "v1.0.0"
"github.com/demo/zero" = "v0.1.0"
EOF
mb "$P" build
mb "$P" update
check "two: exit 0" code_is 0
check "two: zero updated" has "$S/last.out" "Updated github.com/demo/zero v0.1.0 -> v0.1.1"
check "two: apilib updated to v1.1.0" has "$S/last.out" "Updated github.com/demo/apilib v1.0.0 -> v1.1.0"
check "two: apilib v1.2.0 held" has "$S/last.out" "Held github.com/demo/apilib v1.2.0: src/main.mettle:5: Undefined function 'al_mul'"
check "two: zero in mbuild.toml" grep -q '"github.com/demo/zero" = "v0.1.1"' "$P/mbuild.toml"

echo "== update v0 lines"
git -C "$G/vecmath" tag v0.3.0 v0.2.0
P="$S/updv0"
MAIN='import "github.com/demo/vecmath/vecmath";
fn main() -> int32 { return 0; }' proj "$P" <<'EOF'
"github.com/demo/vecmath" = "v0.1.0"
EOF
mb "$P" build
mb "$P" update
check "v0: Newer line" has "$S/last.out" "Newer github.com/demo/vecmath v0.3.0 is a new compatibility line (v0.3)"
check "v0: no update" grep -q '"github.com/demo/vecmath" = "v0.1.0"' "$P/mbuild.toml"
mb "$P" update --major github.com/demo/vecmath
check "--major: exit 0" code_is 0
check "--major: v0.3.0" grep -q '"github.com/demo/vecmath" = "v0.3.0"' "$P/mbuild.toml"

echo "== update --dry-run"
P="$S/dry"
MAIN='import "github.com/demo/apilib/apilib";
fn main() -> int32 { return al_mul(1, 2) - 2; }' proj "$P" <<'EOF'
"github.com/demo/apilib" = "v1.0.0"
EOF
mb "$P" build
cp "$P/mbuild.toml" "$S/toml.before"; cp "$P/mbuild.lock" "$S/lock.before"
mb "$P" update --dry-run
check "dry: exit 0" code_is 0
check "dry: Would update" has "$S/last.out" "Would update github.com/demo/apilib v1.0.0 -> v1.2.0"
check "dry: API report" has "$S/last.out" "API changes from v1.0.0 to v1.2.0 (inside line v1, which should not break):"
check "dry: removed al_mul" has "$S/last.out" "removed  fn al_mul(a: int32, b: int32) -> int32"
check "dry: mbuild.toml unchanged" same "$P/mbuild.toml" "$S/toml.before"
check "dry: mbuild.lock unchanged" same "$P/mbuild.lock" "$S/lock.before"

echo "== get rollback"
mb "$P" get github.com/demo/apilib@v1.2.0
check "get: exit 1" code_is 1
check "get: Verifying" has "$S/last.out" "Verifying 1 bin for linux"
check "get: headline" has "$S/last.out" "error: github.com/demo/apilib v1.2.0 breaks this project:"
check "get: error line" has "$S/last.out" "    src/main.mettle:2: Undefined function 'al_mul' (E0003)"
check "get: API changes" has "$S/last.out" "  API changes from v1.0.0 to v1.2.0 (inside line v1, which should not break):"
check "get: used at" has "$S/last.out" "used at src/main.mettle:2"
check "get: Restored" has "$S/last.out" "  Restored mbuild.toml and mbuild.lock"
check "get: help" has "$S/last.out" "help: stay on v1.0.0 (\`mbuild get github.com/demo/apilib@v1.0.0\`), or take it and fix the code: \`mbuild get github.com/demo/apilib@v1.2.0 --no-verify\`"
check "get: mbuild.toml restored" same "$P/mbuild.toml" "$S/toml.before"
check "get: mbuild.lock restored" same "$P/mbuild.lock" "$S/lock.before"
mb "$P" get github.com/demo/apilib@v1.2.0 --no-verify
check "get --no-verify: exit 0" code_is 0
check "get --no-verify: taken" grep -q '"github.com/demo/apilib" = "v1.2.0"' "$P/mbuild.toml"

echo "== get conflict rollback"
P="$S/conf"
rm -rf "$P"; cp -r "$F/app" "$P"
printf '"github.com/demo/strutil" = "v1.0.0"\n"github.com/demo/nomanifest" = "main"\n' >>"$P/mbuild.toml"
sed -i 's/vecmath" = "v0.1.0"/vecmath" = "v0.2.0"/' "$P/mbuild.toml"
mb "$P" build
cp "$P/mbuild.toml" "$S/toml.before"
mb "$P" get github.com/demo/strutil@v2.0.0-rc.1
check "conflict: exit 1" code_is 1
check "conflict: error" has "$S/last.out" "required at incompatible versions"
check "conflict: mbuild.toml unchanged" same "$P/mbuild.toml" "$S/toml.before"

echo "== --locked update"
cp "$P/mbuild.lock" "$S/lock.before"
mb "$P" update --locked
check "--locked update: exit 1" code_is 1
check "--locked update: refused" has "$S/last.out" "--locked forbids it"
check "--locked update: lock unchanged" same "$P/mbuild.lock" "$S/lock.before"

echo "== why / outdated through main"
P="$S/why"
rm -rf "$P"; cp -r "$F/app" "$P"
printf '"github.com/demo/strutil" = "v1.0.0"\n"github.com/demo/nomanifest" = "main"\n' >>"$P/mbuild.toml"
sed -i 's/vecmath" = "v0.1.0"/vecmath" = "v0.2.0"/' "$P/mbuild.toml"
mb "$P" build
mb "$P" why github.com/demo/strutil
check "why MODULE" has "$S/last.out" "github.com/demo/strutil v1.1.0 (selected: the highest of the versions required)"
check "why MODULE: imported by" has "$S/last.out" "github.com/demo/vecmath v0.2.0: vecmath.mettle:1"
mb "$P" why main Audit
check "why A B reaches the compiler" hasnt "$S/last.out" "is not a dependency"
P="$S/outd"
proj "$P" <<'EOF'
"github.com/demo/apilib" = "v1.0.0"
"github.com/demo/vecmath" = "v0.1.0"
EOF
mb "$P" outdated
tr -s ' ' <"$S/last.out" >"$S/outd.txt"; cp "$S/outd.txt" "$S/last.out"
check "outdated apilib row" has "$S/last.out" "github.com/demo/apilib v1.0.0 v1.2.0 v2.0.0 (new line) mbuild.toml"
check "outdated vecmath row" has "$S/last.out" "github.com/demo/vecmath v0.1.0 - v0.3.0 (new line) mbuild.toml"

echo "== mettle minimum in build"
P="$S/needs"
MAIN='import "github.com/demo/needs/needs";
fn main() -> int32 { return needs_val() - 9; }' proj "$P" <<'EOF'
"github.com/demo/needs" = "v1.0.0"
EOF
(cd "$P" && MBUILD_METTLE_LINUX="$L017" "$MB" build) >"$S/last.out" 2>&1; echo $? >"$S/last.code"
check "needs: exit 1" code_is 1
check "needs: 12.11 error" has "$S/last.out" "error: github.com/demo/needs v1.0.0 needs Mettle v0.99.0 or newer; the linux compiler is v0.17.0"
check "needs: newest supporting" has "$S/last.out" "or require github.com/demo/needs v0.9.0, the newest version that supports Mettle v0.17.0"
sed -i 's/v1.0.0/v0.9.0/' "$P/mbuild.toml"
(cd "$P" && MBUILD_METTLE_LINUX="$L017" "$MB" build) >"$S/last.out" 2>&1; echo $? >"$S/last.code"
check "needs v0.9.0 builds" code_is 0

echo "== project submodule"
P="$S/subp"
rm -rf "$P"; mkdir -p "$P/src"
git init -q -b main "$P"
git -C "$P" config user.email t@t; git -C "$P" config user.name t
printf '[package]\nname = "subp"\n\n[c]\ninclude = ["vendor/deep/include"]\n' >"$P/mbuild.toml"
printf 'fn main() -> int32 { return 0; }\n' >"$P/src/main.mettle"
git -C "$P" -c protocol.file.allow=always submodule add -q "$G/deep" vendor/deep
git -C "$P" add -A; git -C "$P" commit -q -m init
git -C "$P" submodule deinit -q -f vendor/deep
git -C "$P" status --porcelain >"$S/st.before"
mb "$P" build
check "submodule: exit 1" code_is 1
check "submodule: error" has "$S/last.out" "error: [c] include entry vendor/deep/include is inside the git submodule vendor/deep, which is not checked out"
check "submodule: help" has "$S/last.out" "help: run \`git submodule update --init --recursive vendor/deep\` (or \`mbuild fetch --submodules\`)"
git -C "$P" status --porcelain >"$S/st.after"
check "submodule: git status unchanged" same "$S/st.before" "$S/st.after"
mb "$P" fetch
check "fetch: note" has "$S/last.out" "git submodules vendor/deep are not checked out"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always mb "$P" fetch --submodules
check "fetch --submodules: line" has "$S/last.out" "Updating git submodules vendor/deep (git submodule update --init --recursive)"
mb "$P" build
check "submodule: builds after fetch" code_is 0
mb "$P" doctor
check "doctor lists the submodule" grep -q "vendor/deep *ok" "$S/last.out"

echo "== clash note"
P="$S/clash"
MAIN='import "github.com/demo/clash1/clash1";
import "github.com/demo/clash2/clash2";
fn main() -> int32 { return clash_name(); }' proj "$P" <<'EOF'
"github.com/demo/clash1" = "v1.0.0"
"github.com/demo/clash2" = "v1.0.0"
EOF
mb "$P" build
check "clash: exit 1" code_is 1
check "clash: note" has "$S/last.out" "note: \`clash_name\` is exported by both github.com/demo/clash2 (clash2.mettle:1) and github.com/demo/clash1 (clash1.mettle:1); plain imports share one namespace"
check "clash: help" has "$S/last.out" "help: import one of them under a name: import \"github.com/demo/clash1/clash1\" as clash1;"

echo "== local tools"
P="$S/tools"
proj "$P" </dev/null
printf '[tools]\nmettle-linux = "%s"\n' "$HEAD" >"$P/mbuild.local.toml"
(cd "$P" && env -u MBUILD_METTLE_LINUX "$MB" doctor) >"$S/last.out" 2>&1
check "doctor names mbuild.local.toml" has "$S/last.out" "(mbuild.local.toml)"
(cd "$P" && MBUILD_METTLE_LINUX="$L017" "$MB" doctor) >"$S/last.out" 2>&1
check "the variable wins" has "$S/last.out" "MBUILD_METTLE_LINUX"

echo "== init"
P="$S/initp"
rm -rf "$P"; mkdir -p "$P"
mb "$P" init
check "init: .gitignore has mbuild.local.toml" grep -qx "/mbuild.local.toml" "$P/.gitignore"

if [ -z "${E2E_NO_WINE:-}" ] && [ -f "$W017" ] && command -v wine >/dev/null 2>&1; then
  echo "== wine: settings for the windows target"
  P="$S/setw"
  proj "$P" </dev/null
  mb "$P" -v build -t windows
  check "windows: debug passes -s" has "$S/last.out" " -s"
  mb "$P" -v build -t windows -r
  check "windows: release passes --release" has "$S/last.out" "--release"
  printf '\n[profile.release]\ncheck-overflow = true\n' >>"$P/mbuild.toml"
  mb "$P" build -t windows -r
  check "windows: exit 1" code_is 1
  check "windows: 12.12 error" has "$S/last.out" "check-overflow = true needs a Mettle compiler that has --check-overflow; the windows compiler ("
fi

echo
echo "$pass passed, $failed failed"
[ "$failed" = 0 ]
