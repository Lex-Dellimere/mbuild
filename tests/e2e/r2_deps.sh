#!/bin/sh
# r2_deps.sh: round-2 acceptance tests of src/deps.mettle (DESIGN.md 12.21
# group D), with a real mbuild built from this tree (head compiler) and, for
# commands build.mettle/main.mettle do not dispatch yet, tests/deps_driver.
#
#   sh tests/r2_deps.sh
#
# Scratch: /tmp/opencode/r2-D (MBUILD_HOME inside it; toolchains -> ~/.mbuild/toolchains).

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
HEAD="${METTLE_HEAD:-$here/../Mettle/bin/mettle}"
L017="${METTLE_L017:-$HOME/.mbuild/toolchains/v0.17.0/linux/bin/mettle}"
S=/tmp/opencode/r2-D
rm -rf "$S"
mkdir -p "$S"
export LC_ALL=C NO_COLOR=1

pass=0
failed=0
pending=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -30; }
check() { name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$S/last.out" 2>/dev/null)"; fi; }
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
code_is() { [ "$(cat "$S/last.code")" = "$1" ]; }
not() { ! "$@"; }
lockv() { awk -v m="$2" '$1 == m { print $2 }' "$1/mbuild.lock"; }

echo "== building mbuild and the driver"
"$HEAD" --build "$here/src/main.mettle" -o "$S/mbuild" >"$S/build.log" 2>&1 || { cat "$S/build.log"; exit 1; }
"$HEAD" --build "$here/tests/unit/deps_driver.mettle" -o "$S/drv" >"$S/dbuild.log" 2>&1 || { cat "$S/dbuild.log"; exit 1; }
MB="$S/mbuild"
D="$S/drv"

F="$S/fx"
"$here/tests/fixtures/make-fixtures.sh" "$F" >/dev/null
sh "$here/tests/fixtures/make-fixtures-r2.sh" "$F" >/dev/null
G="$F/gitbase/github.com/demo"
export MBUILD_HOME="$S/home"
mkdir -p "$MBUILD_HOME"
ln -s "$HOME/.mbuild/toolchains" "$MBUILD_HOME/toolchains"
export MBUILD_GIT_BASE="$F/gitbase"
export MBUILD_METTLE_LINUX="$HEAD"

mb() { (cd "$1" && shift && "$MB" "$@") >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }
drv() { "$D" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }
# proj DIR then dependency lines on stdin; main.mettle from $MAIN
proj() {
  rm -rf "$1"; mkdir -p "$1/src"
  { printf '[package]\nname = "%s"\n\n[dependencies]\n' "$(basename "$1")"; cat; } >"$1/mbuild.toml"
  printf '%s\n' "${MAIN:-fn main() -> int32 { return 0; \}}" >"$1/src/main.mettle"
}

echo "== cross-line conflict"
P="$S/cross"
MAIN='import "github.com/demo/old/old";
import "github.com/demo/new2/new2";
fn main() -> int32 { return 0; }' proj "$P" <<'EOF'
"github.com/demo/old" = "v1.0.0"
"github.com/demo/new2" = "v1.0.0"
EOF
mb "$P" build
check "cross-line exits 1" code_is 1
check "cross-line headline" has "$S/last.out" "error: github.com/demo/apilib is required at incompatible versions:"
check "cross-line v1 row" has "$S/last.out" "    v1.0.0 (line v1) by mbuild.toml -> github.com/demo/old v1.0.0"
check "cross-line v2 row" has "$S/last.out" "    v2.0.0 (line v2) by mbuild.toml -> github.com/demo/new2 v1.0.0"
check "cross-line upgrade help" has "$S/last.out" "help: github.com/demo/old v1.1.0 requires github.com/demo/apilib v2.0.0: run \`mbuild get github.com/demo/old@v1.1.0\`"
check "cross-line replace help" has "$S/last.out" '"github.com/demo/apilib" = { version = "v2.0.0" }'
check "cross-line: no lock written" [ ! -f "$P/mbuild.lock" ]

echo "== v0 lines"
P="$S/zero"
proj "$P" <<'EOF'
"github.com/demo/z1" = "v1.0.0"
"github.com/demo/z2" = "v1.0.0"
EOF
mb "$P" build
check "v0 conflict exits 1" code_is 1
check "v0.1 row" has "$S/last.out" "v0.1.0 (line v0.1)"
check "v0.2 row" has "$S/last.out" "v0.2.0 (line v0.2)"
check "v0: no upgrade help" hasnt "$S/last.out" "run \`mbuild get"

echo "== [replace] version"
P="$S/repver"
proj "$P" <<'EOF'
"github.com/demo/old" = "v1.0.0"
"github.com/demo/new2" = "v1.0.0"

[replace]
"github.com/demo/apilib" = { version = "v2.0.0" }
EOF
mb "$P" deps
check "replace version resolves" code_is 0
check "lock has apilib v2.0.0" [ "$(lockv "$P" github.com/demo/apilib)" = v2.0.0 ]
check "deps shows the replacement" has "$S/last.out" "github.com/demo/apilib => v2.0.0 (replaced)"

echo "== [replace] path"
git clone -q "$G/strutil" "$S/strutil-local"
sed -i 's/return "strutil v[^"]*"/return "local"/' "$S/strutil-local/strutil.mettle"
P="$S/app"
rm -rf "$P"; cp -r "$F/app" "$P"
cat >>"$P/mbuild.toml" <<'EOF'
"github.com/demo/strutil" = "v1.0.0"
"github.com/demo/nomanifest" = "main"

[replace]
"github.com/demo/strutil" = { path = "../strutil-local" }
EOF
mb "$P" run
check "replace path: run works" code_is 0
check "replace path: prints local" has "$S/last.out" "local"
check "replace path: a link" [ -L "$P/.mbuild/deps/github.com/demo/strutil" ]
check "replace path: no lock line" hasnt "$P/mbuild.lock" "github.com/demo/strutil"
sum_local() { (cat "$S/strutil-local/strutil.mettle"; find "$S/strutil-local/.git" -type f | sort | xargs cat) | md5sum; }
before="$(sum_local)"
mb "$P" build --force
check "build --force works" code_is 0
check "build --force leaves the local checkout" [ "$(sum_local)" = "$before" ]
drv "$P" ensure
check "DepModule.replaced = path, dir = real dir" grep -q "^MOD github.com/demo/strutil .*replaced=path .*dir=$S/strutil-local$" "$S/last.out"
sed -i '/^\[replace\]/,$d' "$P/mbuild.toml"
mb "$P" build
check "without the replacement: builds" code_is 0
check "checked out again" [ -f "$P/.mbuild/deps/github.com/demo/strutil/.mbuild-commit" ] && [ ! -L "$P/.mbuild/deps/github.com/demo/strutil" ]
check "the local dir is unchanged" [ "$(sum_local)" = "$before" ]

echo "== [replace] in mbuild.local.toml"
cp "$P/mbuild.lock" "$S/lock.before"
printf '[replace]\n"github.com/demo/strutil" = { path = "../strutil-local" }\n' >"$P/mbuild.local.toml"
mb "$P" run
check "local replace: run prints local" has "$S/last.out" "local"
check "local replace: note" has "$S/last.out" "note: using replacements from mbuild.local.toml (github.com/demo/strutil); mbuild.lock is left as it is"
check "local replace: mbuild.lock byte-identical" cmp -s "$P/mbuild.lock" "$S/lock.before"
check "local replace: .mbuild/local.lock" [ -f "$P/.mbuild/local.lock" ]
mb "$P" build --locked
check "local replace: --locked succeeds" code_is 0
rm -f "$P/mbuild.local.toml"

echo "== importing yourself"
P="$S/selfy"
rm -rf "$P"; mkdir -p "$P/cmd/demo"
printf '[package]\nname = "selfy"\nmodule = "github.com/me/selfy"\n' >"$P/mbuild.toml"
printf 'export fn f() -> int32 { return 7; }\n' >"$P/lib.mettle"
printf 'import "std/io";\nimport "github.com/me/selfy/lib";\nfn main() -> int32 { println("f={f()}"); return 0; }\n' >"$P/cmd/demo/main.mettle"
mb "$P" run demo
check "self import: run demo" has "$S/last.out" "f=7"

echo "== submodules"
P="$S/subs"
MAIN='import "std/io";
import "github.com/demo/wrapper/wrapper";
fn main() -> int32 { println("v={clib_value()}"); return 0; }' proj "$P" <<'EOF'
"github.com/demo/wrapper" = "v1.0.0"
EOF
mb "$P" run
check "wrapper v1.0.0 prints 42" has "$S/last.out" "v=42"
mb "$P" deps
check "deps notes the submodules" has "$S/last.out" "[submodules: vendor/clib]"
mb "$P" build -v
check "second build runs no git" hasnt "$S/last.out" "advice.detached"
mb "$P" get github.com/demo/wrapper@v1.1.0
mb "$P" run
check "wrapper v1.1.0 prints 43" has "$S/last.out" "v=43"
mb "$P" fetch
rm -rf "$MBUILD_HOME/git/sub"
mb "$P" build --offline
check "offline build with current checkouts" code_is 0
rm -rf "$P/.mbuild"
mb "$P" build --offline
check "offline without submodule mirrors fails" code_is 1
check "the 12.7 offline error" has "$S/last.out" "submodule vendor/clib of github.com/demo/wrapper v1.1.0 (from $F/gitbase/github.com/demo/clib) is not downloaded and --offline forbids fetching it"

echo "== old one-line marker"
mb "$P" build
W="$P/.mbuild/deps/github.com/demo/wrapper"
head -1 "$W/.mbuild-commit" >"$S/m1"; cp "$S/m1" "$W/.mbuild-commit"
mb "$P" build -v
check "old marker: slow path once" has "$S/last.out" "Resolving"
check "old marker: no parent re-clone" not grep -q "clone -q --shared .*/wrapper@" "$S/last.out"
check "old marker regains subs 2" [ "$(sed -n 2p "$W/.mbuild-commit")" = "subs 2" ]

echo "== submodules = false"
P="$S/nosubs"
MAIN='import "std/io";
import "github.com/demo/wrapper/wrapper";
fn main() -> int32 { println("v={clib_value()}"); return 0; }' proj "$P" <<'EOF'
"github.com/demo/wrapper" = { version = "v1.0.0", submodules = false }
EOF
mb "$P" build
check "submodules = false: the C compile fails" code_is 1
check "vendor/clib is empty" [ -z "$(ls -A "$P/.mbuild/deps/github.com/demo/wrapper/vendor/clib" 2>/dev/null)" ]
check "marker subs 0" grep -q "^subs 0" "$P/.mbuild/deps/github.com/demo/wrapper/.mbuild-commit"
drv "$P" get github.com/demo/wrapper@v1.1.0
check "editing keeps submodules = false" has "$P/mbuild.toml" 'submodules = false'

echo "== typo"
P="$S/typo"
MAIN='import "github.com/demo/vecmath/vecmath";
fn main() -> int32 { return 0; }' proj "$P" <<'EOF'
"github.com/demo/vecmath" = "v0.1.0"
EOF
mb "$P" build
mb "$P" get github.com/demo/strutill
check "typo exits 1" code_is 1
check "typo suggestion" has "$S/last.out" "did you mean github.com/demo/strutil? (in mbuild.lock)"

echo "== gone after lock"
P="$S/gone"
MAIN='import "github.com/demo/strutil/strutil";
fn main() -> int32 { return 0; }' proj "$P" <<'EOF'
"github.com/demo/strutil" = "v1.1.0"
EOF
mb "$P" build
mv "$G/strutil" "$G/strutil.away"
mb "$P" update github.com/demo/strutil
check "gone: update exits 0" code_is 0
check "gone: warning" has "$S/last.out" "is no longer available from"
mb "$P" build
check "gone: build works" code_is 0
mv "$G/strutil.away" "$G/strutil"

echo "== network"
P="$S/net"
rm -rf "$P"; cp -r "$F/app" "$P"
mb "$P" build
mb "$P" update
cp "$P/mbuild.lock" "$S/lock.before"
printf '[url "https://nonexistent.invalid/"]\n\tinsteadOf = %s/\n' "$F/gitbase" >"$S/gitconfig"
(export GIT_CONFIG_GLOBAL="$S/gitconfig"; mb "$P" update)
check "network: update exits 0" code_is 0
check "network: warning" has "$S/last.out" "warning: network unavailable (git: Could not resolve host: nonexistent.invalid); using the cached mirror of"
check "network: lock unchanged" cmp -s "$P/mbuild.lock" "$S/lock.before"
P2="$S/net2"
proj "$P2" <<'EOF'
"github.com/demo/clash1" = "v1.0.0"
EOF
(export GIT_CONFIG_GLOBAL="$S/gitconfig"; mb "$P2" build)
check "network, no mirror: error" has "$S/last.out" "error: cannot download github.com/demo/clash1 (required by mbuild.toml): the network is unavailable"

echo "== force-pushed history"
P="$S/force"
MAIN='import "github.com/demo/nomanifest/greet";
fn main() -> int32 { return 0; }' proj "$P" <<'EOF'
"github.com/demo/nomanifest" = "main"
EOF
mb "$P" build
locked="$(awk '$1 == "github.com/demo/nomanifest" { print $3 }' "$P/mbuild.lock")"
git -C "$G/nomanifest" commit -q --amend -m "rewritten"
git -C "$G/nomanifest" reflog expire --expire=now --all
git -C "$G/nomanifest" gc -q --prune=now
rm -rf "$P/.mbuild"
mb "$P" build
check "kept mirror: builds" code_is 0
rm -rf "$P/.mbuild" "$MBUILD_HOME"/git/github.com/demo/nomanifest*
mb "$P" build
check "force-push: exit 1" code_is 1
check "force-push: 12.6 error" has "$S/last.out" "error: commit $(printf %.7s "$locked") of github.com/demo/nomanifest (pinned in mbuild.lock as main) is no longer in $F/gitbase/github.com/demo/nomanifest"
check "force-push: help" has "$S/last.out" "or vendor dependencies (\`mbuild vendor\`) to keep exact copies"

echo "== why (driver: main.mettle does not dispatch it yet)"
P="$S/why"
rm -rf "$P"; cp -r "$F/app" "$P"
printf '"github.com/demo/strutil" = "v1.0.0"\n"github.com/demo/nomanifest" = "main"\n' >>"$P/mbuild.toml"
sed -i 's/vecmath" = "v0.1.0"/vecmath" = "v0.2.0"/' "$P/mbuild.toml"
drv "$P" why github.com/demo/strutil
cat >"$S/why.want" <<'EOF'
github.com/demo/strutil v1.1.0 (selected: the highest of the versions required)
  required by:
    mbuild.toml requires v1.0.0
    mbuild.toml -> github.com/demo/vecmath v0.2.0 requires v1.1.0
  imported by:
    src/main.mettle:3
    github.com/demo/vecmath v0.2.0: vecmath.mettle:1
EOF
grep -v '^ *\(Fetching\|Resolving\|Adding\|Updating\)' "$S/last.out" >"$S/why.got"
check "why prints the 12.4 lines" cmp -s "$S/why.got" "$S/why.want"
drv "$P" why nothere
check "why of a non-dependency" has "$S/last.out" "'nothere' is not a dependency of this project (with two arguments, \`mbuild why A B\` asks the compiler)"
drv "$P" why github.com/x/y
check "why of a module not in the build" has "$S/last.out" "github.com/x/y is not in the build"
pending=$((pending + 1)); echo "PENDING (group B) mbuild why MODULE / why A B dispatch"

echo "== outdated (driver)"
git -C "$G/vecmath" tag v0.3.0 v0.2.0
P="$S/outd"
proj "$P" <<'EOF'
"github.com/demo/apilib" = "v1.0.0"
"github.com/demo/vecmath" = "v0.1.0"
EOF
drv "$P" outdated
tr -s ' ' <"$S/last.out" >"$S/outd.txt"; cp "$S/outd.txt" "$S/last.out"
check "outdated apilib row" has "$S/last.out" "github.com/demo/apilib v1.0.0 v1.2.0 v2.0.0 (new line) mbuild.toml"
check "outdated vecmath row" has "$S/last.out" "github.com/demo/vecmath v0.1.0 - v0.3.0 (new line) mbuild.toml"
drv "$P" outdated -v github.com/demo/apilib
check "outdated -v subject" has "$S/last.out" "v1.2.0 apilib 1.2.0: al_add takes 3, al_mul removed"
check "outdated MODULE: API report" has "$S/last.out" "API changes from v1.0.0 to v2.0.0:"
drv "$P" api github.com/demo/apilib v1.0.0 v1.2.0
check "api report inside a line" has "$S/last.out" "  API changes from v1.0.0 to v1.2.0 (inside line v1, which should not break):"
check "api report: removed al_mul" has "$S/last.out" "    removed  fn al_mul(a: int32, b: int32) -> int32"
check "api report: no added by default" hasnt "$S/last.out" "added"
drv "$P" plan
check "plan: apilib compatible" has "$S/last.out" "PLAN github.com/demo/apilib v1.0.0 -> v1.2.0 compatible [v1.2.0 v1.1.0]"
check "plan: vecmath new line" has "$S/last.out" "LINE github.com/demo/vecmath v0.3.0"
cp "$P/mbuild.toml" "$S/toml.before"; cp "$P/mbuild.lock" "$S/lock.before"
drv "$P" restore-after github.com/demo/apilib v1.2.0
check "apply then restore" has "$S/last.out" "RESTORED"
check "restore: mbuild.toml back" cmp -s "$P/mbuild.toml" "$S/toml.before"
check "restore: mbuild.lock back" cmp -s "$P/mbuild.lock" "$S/lock.before"
check "restore: checkout back" [ "$(head -1 "$P/.mbuild/deps/github.com/demo/apilib/.mbuild-commit")" = "$(git -C "$G/apilib" rev-parse 'v1.0.0^{commit}')" ]
pending=$((pending + 1)); echo "PENDING (group B) mbuild outdated / update verification end to end"

echo "== mettle minimum (driver)"
P="$S/needs"
proj "$P" <<'EOF'
"github.com/demo/needs" = "v1.0.0"
EOF
MBUILD_METTLE_LINUX="$L017" drv "$P" mettle
check "needs v1.0.0: exit 1" code_is 1
check "needs: the 12.11 error" has "$S/last.out" "error: github.com/demo/needs v1.0.0 needs Mettle v0.99.0 or newer; the linux compiler is v0.17.0"
check "needs: newest supporting" has "$S/last.out" "or require github.com/demo/needs v0.9.0, the newest version that supports Mettle v0.17.0"
drv "$P" deps
check "deps: Mettle line" has "$S/last.out" "Mettle >= v0.99.0 (github.com/demo/needs)"
sed -i 's/v1.0.0/v0.9.0/' "$P/mbuild.toml"
MBUILD_METTLE_LINUX="$L017" drv "$P" mettle
check "needs v0.9.0 passes" has "$S/last.out" "METTLE OK"
pending=$((pending + 1)); echo "PENDING (group B) the minimum check inside mbuild build"

echo "== mettle.deps"
P="$S/md"
mkdir -p "$S/foo"; printf 'export fn foo_v() -> int32 { return 5; }\n' >"$S/foo/foo.mettle"
MAIN='import "std/io";
import "foo/foo";
import "github.com/demo/strutil/strutil";
fn main() -> int32 { println("foo={foo_v()}"); return 0; }' proj "$P" <<'EOF'
"github.com/demo/strutil" = "v1.0.0"
EOF
printf 'foo=../foo\n' >"$P/mettle.deps"
mb "$P" build
check "unmanaged line warning" has "$S/last.out" "warning: mettle.deps:1: \`foo=../foo\` is not managed by mbuild (its dependencies and C code are ignored)"
check "unmanaged line help" has "$S/last.out" "run \`mbuild tidy\` to move it into mbuild.toml as foo = { path = \"../foo\" }"
mb "$P" tidy
check "tidy adopts" has "$S/last.out" "Adopted foo = { path = \"../foo\" } from mettle.deps"
check "line gone from mettle.deps (only the block publishes foo)" [ "$(grep -c "^foo=../foo$" "$P/mettle.deps")" = 1 ]
check "[dependencies] foo" grep -q '^foo = { path = "../foo" }' "$P/mbuild.toml"
mb "$P" run
check "adopted package still works" has "$S/last.out" "foo=5"
{ printf 'github.com=./x\n'; cat "$P/mettle.deps"; } >"$S/md.tmp"; mv "$S/md.tmp" "$P/mettle.deps"
rm -f "$P/.mbuild/deps.stamp"
mb "$P" build
check "shadow warning" has "$S/last.out" "warning: mettle.deps:1: \`github.com=./x\` shadows mbuild's entry for github.com; remove it"

echo "== lock merge conflict"
P="$S/merge"
MAIN='import "github.com/demo/strutil/strutil";
fn main() -> int32 { return 0; }' proj "$P" <<'EOF'
"github.com/demo/strutil" = "v1.0.0"
EOF
mb "$P" build
c10="$(git -C "$G/strutil" rev-parse 'v1.0.0^{commit}')"
c11="$(git -C "$G/strutil" rev-parse 'v1.1.0^{commit}')"
reqs="$(grep '^# requirements' "$P/mbuild.lock")"
printf '# mbuild.lock: generated by mbuild. Commit it.\n<<<<<<< HEAD\n%s\n# module version commit\ngithub.com/demo/strutil v1.0.0 %s\n=======\n%s\n# module version commit\ngithub.com/demo/strutil v1.1.0 %s\n>>>>>>> other\n' "$reqs" "$c10" "$reqs" "$c11" >"$P/mbuild.lock"
cp "$P/mbuild.lock" "$S/conflicted.lock"
mb "$P" build --locked
check "--locked: exit 1" code_is 1
check "--locked: markers error" has "$S/last.out" "mbuild.lock has merge conflict markers"
mb "$P" build
check "repair: exit 0" code_is 0
check "repair: message" has "$S/last.out" "Repaired merge conflict in mbuild.lock"
check "repair: no markers left" not grep -q '^\(<<<<<<<\|=======\|>>>>>>>\)' "$P/mbuild.lock"
check "repair: strutil per MVS (the requirement, v1.0.0)" [ "$(lockv "$P" github.com/demo/strutil)" = v1.0.0 ]

echo "== old lock compatibility"
OLD="$S/old"
mkdir -p "$OLD"
git -C "$here" archive HEAD src tests/deps_driver.mettle | tar -x -C "$OLD"
"$HEAD" --build "$OLD/tests/deps_driver.mettle" -o "$S/olddrv" >"$S/olddrv.log" 2>&1
P="$S/oldlock"
rm -rf "$P"; cp -r "$F/app" "$P"
printf '"github.com/demo/strutil" = "v1.0.0"\n"github.com/demo/nomanifest" = "main"\n' >>"$P/mbuild.toml"
"$S/olddrv" "$P" ensure >/dev/null 2>&1
cp "$P/mbuild.lock" "$S/old.lock"
rm -rf "$P/.mbuild"
mb "$P" build --locked
check "old lock: build --locked succeeds" code_is 0
check "old lock: unchanged" cmp -s "$P/mbuild.lock" "$S/old.lock"

echo
echo "$pass passed, $failed failed, $pending pending on group B"
[ "$failed" = 0 ]
