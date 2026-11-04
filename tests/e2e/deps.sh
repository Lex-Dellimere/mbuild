#!/bin/sh
# deps.sh: dependencies over the registry fixtures (tests/unit/deps_test.mettle and the CLI).
#   METTLE=dev-compiler sh tests/e2e/deps.sh   (scratch: $MBTEST_TMP)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
S="${MBTEST_TMP:-/tmp/mbuild-test-$USER/deps}"
rm -rf "$S"
mkdir -p "$S"
export LC_ALL=C NO_COLOR=1

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -30; }
check() { name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$S/last.out" 2>/dev/null)"; fi; }
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
code_is() { [ "$(cat "$S/last.code")" = "$1" ]; }
lockv() { awk -v m="$2" '$1 == m { print $2 }' "$1/mbuild.lock"; }
lockline() { awk -v m="$2" '$1 == m' "$1/mbuild.lock"; }
idxsha() { awk -v v="$3" '$1 == v { sub("sha256=", "", $2); print $2 }' "$1/index/$2"; }

D="${DRV:-}"
if [ -z "$D" ]; then
  echo "== building the driver"
  "$METTLE" --build "$here/tests/unit/deps_test.mettle" -o "$S/drv" >"$S/dbuild.log" 2>&1 || { cat "$S/dbuild.log"; exit 1; }
  D="$S/drv"
fi

F="$S/fx"
sh "${MAKE_REGISTRY:-$here/tests/fixtures/make-registry.sh}" "$F" >/dev/null || exit 1
R="$F/registry"
C="$S/corpfx"
sh "${MAKE_REGISTRY:-$here/tests/fixtures/make-registry.sh}" "$C" >/dev/null || exit 1
export MBUILD_HOME="$S/home"
export MBUILD_REGISTRY="$R"
export MBUILD_METTLE_LINUX="$METTLE"
mkdir -p "$MBUILD_HOME"

drv() { "$D" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }
# proj DIR then lines of fn project() on stdin; src/main.mettle from $MAIN
proj() {
  rm -rf "$1"; mkdir -p "$1/src"
  { printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("%s", "v0.1.0");\n' "$(basename "$1")"; sed 's/^/  /'; printf '}\n'; } >"$1/mbuild.mettle"
  printf '%s\n' "${MAIN:-fn main() -> int32 { return 0; \}}" >"$1/src/main.mettle"
}

# unit NAME: tests/unit/NAME.mettle built debug and --release, both runs agree
unit() { if out=$(METTLE="$METTLE" TMPDIR="$S" sh "$here/tools/mcheck.sh" "$here/tests/unit/$1.mettle" --run 2>&1); then ok "$1 ($(printf '%s\n' "$out" | sed -n 's/^\[run\] ok (.*: \(.*\))$/\1/p'))"; else bad "$1" "$out"; fi; }

echo "== unit tests"
unit semver_test

echo "== auto-add and the lock"
P="$S/app"
MAIN='import "strutil/strutil";
import "vecmath/vecmath";
fn main() -> int32 { return su_ver() + vm_one(); }' proj "$P" <<'EOF'
mb_dep("vecmath", "v0.2.0");
EOF
before=$(wc -l <"$P/mbuild.mettle")
drv "$P" auto strutil vecmath
check "auto exits 0" code_is 0
check "auto adds strutil" has "$S/last.out" "Adding strutil v1.1.0 (registry default)"
check "lock: strutil line" [ "$(lockline "$P" strutil)" = "strutil v1.1.0 default sha256:$(idxsha "$R" strutil v1.1.0)" ]
check "lock: vecmath v0.2.0" [ "$(lockv "$P" vecmath)" = "v0.2.0" ]
check "lock: format 3" has "$P/mbuild.lock" "# format 3"
check "mbuild.mettle gained one line" [ "$(wc -l <"$P/mbuild.mettle")" -eq $((before + 1)) ]
check "mbuild.mettle declares strutil" has "$P/mbuild.mettle" 'mb_dep("strutil", "v1.1.0");'
check "package extracted" [ -f "$P/.mbuild/deps/strutil/strutil.mettle" ]
check "root mettle.deps: package" has "$P/mettle.deps" "strutil=./.mbuild/deps/strutil"
check "root mettle.deps: itself" has "$P/mettle.deps" "app=."
check "root mettle.deps: api" has "$P/mettle.deps" "mbuild=./.mbuild/api/mbuild"
check "package block" has "$P/.mbuild/deps/vecmath/mettle.deps" "strutil=../strutil"
drv "$P" ensure -v
check "second ensure: fast path" has "$S/last.out" "mbuild.lock unchanged"
check "second ensure: no resolving" hasnt "$S/last.out" "Resolving"
check "ensure: checksum and registry" has "$S/last.out" "MOD strutil v1.1.0 sha256:$(idxsha "$R" strutil v1.1.0) registry=default"
drv "$P" why strutil
check "why: head" has "$S/last.out" "strutil v1.1.0 (selected: the highest of the versions required)"
check "why: chain" has "$S/last.out" "mbuild.mettle -> vecmath v0.2.0 requires v1.1.0"
check "why: import" has "$S/last.out" "src/main.mettle:1"
drv "$P" deps
check "deps: registry shown" has "$S/last.out" "strutil v1.1.0 (default)"

echo "== cross-line conflict"
P="$S/cross"
proj "$P" <<'EOF'
mb_dep("old", "v1.0.0");
mb_dep("new2", "v1.0.0");
EOF
drv "$P" ensure
check "cross-line exits 1" code_is 1
check "cross-line headline" has "$S/last.out" "error: apilib is required at incompatible versions:"
check "cross-line v1 row" has "$S/last.out" "    v1.0.0 (line v1) by mbuild.mettle -> old v1.0.0"
check "cross-line v2 row" has "$S/last.out" "    v2.0.0 (line v2) by mbuild.mettle -> new2 v1.0.0"
check "cross-line why" has "$S/last.out" "  a program holds one version of a package: two lines would declare the same exported names twice"
check "cross-line upgrade help" has "$S/last.out" "help: old v1.1.0 requires apilib v2.0.0: run \`mbuild get old@v1.1.0\`"
check "cross-line replace help" has "$S/last.out" "help: or choose one version for the whole build in mbuild.mettle (you take responsibility for the others):"
check "cross-line replace call" has "$S/last.out" '          mb_replace_version("apilib", "v2.0.0");'
check "cross-line: no lock" [ ! -f "$P/mbuild.lock" ]

echo "== v0 lines"
P="$S/vzero"
proj "$P" <<'EOF'
mb_dep("z1", "v1.0.0");
mb_dep("z2", "v1.0.0");
EOF
drv "$P" ensure
check "v0 conflict exits 1" code_is 1
check "v0 rows" has "$S/last.out" "v0.1.0 (line v0.1) by mbuild.mettle -> z1 v1.0.0"
check "v0 rows 2" has "$S/last.out" "v0.2.0 (line v0.2) by mbuild.mettle -> z2 v1.0.0"

echo "== replace version"
P="$S/repv"
proj "$P" <<'EOF'
mb_dep("old", "v1.0.0");
mb_dep("new2", "v1.0.0");
mb_replace_version("apilib", "v2.0.0");
EOF
drv "$P" ensure
check "replace version builds" code_is 0
check "replace version selected" has "$S/last.out" "MOD apilib v2.0.0 "
check "replace version kind" has "$S/last.out" "replaced=version"
check "replace version locked" [ "$(lockv "$P" apilib)" = "v2.0.0" ]
drv "$P" why apilib
check "why: replaced" has "$S/last.out" "(selected: replaced in mbuild.mettle)"

echo "== replace path"
mkdir -p "$S/strutil-local"
printf 'export fn su_ver() -> int32 { return 999; }\n' >"$S/strutil-local/strutil.mettle"
P="$S/repp"
proj "$P" <<'EOF'
mb_dep("textfmt", "v0.1.0");
mb_replace_path("strutil", "../strutil-local");
EOF
drv "$P" ensure
check "replace path builds" code_is 0
check "replace path kind" has "$S/last.out" "replaced=path dir=$S/strutil-local"
check "replace path link" [ -L "$P/.mbuild/deps/strutil" ]
check "replace path not locked" [ -z "$(lockline "$P" strutil)" ]
check "replace path: textfmt sees it" has "$P/.mbuild/deps/textfmt/mettle.deps" "strutil=../strutil"

echo "== local replacement"
P="$S/repl"
proj "$P" <<'EOF'
mb_dep("textfmt", "v0.1.0");
EOF
drv "$P" ensure
cp "$P/mbuild.lock" "$S/repl.lock"
printf 'import "mbuild/api";\n\nfn local() {\n  mb_replace_path("strutil", "../strutil-local");\n}\n' >"$P/mbuild.local.mettle"
drv "$P" ensure
check "local replace builds" code_is 0
check "local replace note" has "$S/last.out" "note: using replacements from mbuild.local.mettle (strutil); mbuild.lock is left as it is"
check "local.lock written" [ -f "$P/.mbuild/local.lock" ]
check "mbuild.lock unchanged" cmp -s "$P/mbuild.lock" "$S/repl.lock"
rm "$P/mbuild.local.mettle"
drv "$P" ensure
check "local replace gone: back to the package" [ ! -L "$P/.mbuild/deps/strutil" ]

echo "== outdated"
P="$S/outd"
proj "$P" <<'EOF'
mb_dep("apilib", "v1.0.0");
EOF
drv "$P" outdated
check "outdated row" sh -c "tr -s ' ' <'$S/last.out' | grep -qF 'apilib v1.0.0 v1.2.0 v2.0.0 (new line) mbuild.mettle'"
drv "$P" plan
check "plan in line" has "$S/last.out" "PLAN apilib v1.0.0 -> v1.2.0 compatible [v1.2.0 v1.1.0]"
check "plan new line" has "$S/last.out" "LINE apilib v2.0.0"
drv "$P" api apilib v1.0.0 v1.2.0
check "api report from archives" has "$S/last.out" "removed  fn al_mul"

echo "== mettle minimum"
P="$S/minimum"
proj "$P" <<'EOF'
mb_dep("needs", "v1.0.0");
EOF
drv "$P" mettle
check "minimum" has "$S/last.out" "MIN v0.99.0 | needs v1.0.0"
check "fallback" has "$S/last.out" ", or require needs v0.9.0, the newest version that supports Mettle v0.17.0"

echo "== lock merge repair"
P="$S/merge"
proj "$P" <<'EOF'
mb_dep("strutil", "v1");
EOF
drv "$P" ensure
s0=$(idxsha "$R" strutil v1.0.0); s1=$(idxsha "$R" strutil v1.1.0)
printf '# mbuild.lock: generated by mbuild. Commit it.\n# format 3\n<<<<<<< ours\n# requirements aaa\nstrutil v1.0.0 default sha256:%s\n=======\n# requirements bbb\nstrutil v1.1.0 default sha256:%s\n>>>>>>> theirs\n' "$s0" "$s1" >"$P/mbuild.lock"
drv "$P" ensure --locked
check "conflict + --locked fails" has "$S/last.out" "mbuild.lock has merge conflict markers"
drv "$P" ensure
check "repaired" has "$S/last.out" "Repaired merge conflict in mbuild.lock"
check "repaired: higher kept" [ "$(lockv "$P" strutil)" = "v1.1.0" ]
check "repaired: no markers" hasnt "$P/mbuild.lock" "<<<<<<<"

echo "== registries"
P="$S/pin"
proj "$P" <<EOF
mb_registry("corp", "$C/registry");
mb_dep_from("corp", "strutil", "v1.0.0");
EOF
drv "$P" ensure
check "pinned registry used" [ "$(lockline "$P" strutil | cut -d' ' -f3)" = "corp" ]
P="$S/first"
proj "$P" <<EOF
mb_registry("corp", "$C/registry");
mb_dep("strutil", "v1.0.0");
EOF
drv "$P" ensure
check "unpinned: first in order" [ "$(lockline "$P" strutil | cut -d' ' -f3)" = "corp" ]
P="$S/dflt"
proj "$P" <<'EOF'
mb_dep("strutil", "v1.0.0");
EOF
drv "$P" ensure
check "unpinned: default" [ "$(lockline "$P" strutil | cut -d' ' -f3)" = "default" ]

echo "== yanked"
P="$S/yank"
proj "$P" <<'EOF'
mb_dep("yanky", "latest");
EOF
drv "$P" ensure
check "latest skips yanked" [ "$(lockv "$P" yanky)" = "v1.0.0" ]
sed -i "s/^yanky .*/yanky v1.0.1 default sha256:$(idxsha "$R" yanky v1.0.1)/" "$P/mbuild.lock"
drv "$P" ensure
check "locked yanked builds" code_is 0
check "locked yanked warning" has "$S/last.out" "warning: yanky v1.0.1 is yanked in registry default; mbuild update yanky moves off it"

echo "== integrity"
P="$S/sum"
proj "$P" <<'EOF'
mb_dep("strutil", "v1.1.0");
EOF
drv "$P" ensure
sed -i "s/^strutil .*/strutil v1.1.0 default sha256:$(printf '%064d' 0)/" "$P/mbuild.lock"
drv "$P" ensure
check "lock vs index mismatch fails" code_is 1
check "mismatch headline" has "$S/last.out" "error: strutil v1.1.0 from registry default does not match mbuild.lock"
check "mismatch lock row" has "$S/last.out" "    mbuild.lock   sha256:0000000000000000..."
check "mismatch help" has "$S/last.out" "help: if you trust the new bytes, delete the strutil line from mbuild.lock and build again (review the change first)"
T="$S/tamper"
sh "${MAKE_REGISTRY:-$here/tests/fixtures/make-registry.sh}" "$T" >/dev/null
P="$S/tam"
proj "$P" <<'EOF'
mb_dep("strutil", "v1.1.0");
EOF
MBUILD_REGISTRY="$T/registry" MBUILD_HOME="$S/home-t1" drv "$P" ensure
mkdir -p "$S/evil" && printf 'export fn su_ver() -> int32 { return 666; }\n' >"$S/evil/strutil.mettle"
tar -czf "$T/registry/pkg/strutil/strutil-v1.1.0.tar.gz" -C "$S/evil" strutil.mettle
rm -rf "$P/.mbuild"
MBUILD_REGISTRY="$T/registry" MBUILD_HOME="$S/home-t2" drv "$P" ensure
check "re-tarred archive fails" code_is 1
check "re-tarred archive: mismatch" has "$S/last.out" "does not match"

echo "== git-era lock"
P="$S/era"
proj "$P" <<'EOF'
mb_dep("strutil", "v1.0.0");
EOF
printf '# mbuild.lock: generated by mbuild. Commit it.\n# requirements x\n# module version commit\ngithub.com/demo/strutil v1.0.0 %s\n' "$(printf '%040d' 1)" >"$P/mbuild.lock"
drv "$P" ensure --locked
check "git era --locked fails" code_is 1
check "git era --locked help" has "$S/last.out" "run mbuild once without --locked"
drv "$P" ensure
check "git era note" has "$S/last.out" "note: mbuild.lock is from the git era and is re-resolved"
check "git era re-resolved" [ "$(lockv "$P" strutil)" = "v1.0.0" ]

echo "== offline, vendor"
P="$S/off"
proj "$P" <<'EOF'
mb_dep("textfmt", "v0.1.0");
EOF
cp -r "$F" "$S/fx2"
MBUILD_REGISTRY="$S/fx2/registry" MBUILD_HOME="$S/home-off" drv "$P" fetch
check "fetch" has "$S/last.out" "builds can now run with --offline"
rm -rf "$S/fx2" "$P/.mbuild"
MBUILD_REGISTRY="$S/fx2/registry" MBUILD_HOME="$S/home-off" drv "$P" ensure --offline
check "offline after fetch, registry gone" code_is 0
check "offline: extracted" [ -f "$P/.mbuild/deps/strutil/strutil.mettle" ]
P="$S/ven"
proj "$P" <<'EOF'
mb_dep("textfmt", "v0.1.0");
EOF
drv "$P" vendor
check "vendor" has "$S/last.out" "Vendored 2 package(s) into vendor/"
check "vendor modules.txt" has "$P/vendor/modules.txt" "strutil v1.1.0 sha256:"
rm -rf "$P/.mbuild"
MBUILD_REGISTRY="$S/nowhere" MBUILD_HOME="$S/home-none" drv "$P" ensure
check "vendored build without registry" code_is 0
check "vendored: dirs" has "$S/last.out" "dir=$P/vendor/textfmt"
check "vendored: mettle.deps" has "$P/mettle.deps" "textfmt=./vendor/textfmt"
echo '// changed' >>"$P/mbuild.lock"
MBUILD_REGISTRY="$S/nowhere" drv "$P" ensure
check "vendor out of date" has "$S/last.out" "error: vendor/ is out of date with mbuild.lock"
drv "$P" vendor --remove
check "vendor --remove" [ ! -d "$P/vendor" ]

echo "== errors and edits"
P="$S/miss"
proj "$P" </dev/null
drv "$P" add-missing nosuch
check "no such package" has "$S/last.out" "note: no registry has a package named nosuch (searched default)"
check "no such package: not added" has "$S/last.out" "ADDED 0"
P="$S/branch"
proj "$P" <<'EOF'
mb_dep("strutil", "main");
EOF
drv "$P" ensure
check "branch spec refused" has "$S/last.out" 'error: strutil = "main": registry packages have versions only (v1.2.0, v1, latest)'
P="$S/typo"
proj "$P" <<'EOF'
mb_dep("strutl", "v1.0.0");
EOF
drv "$P" ensure
check "unknown package" has "$S/last.out" "no registry has a package named strutl"
mkdir -p "$S/widgets" && printf '[package]\nname = "widgets"\n' >"$S/widgets/mbuild.toml"
P="$S/legacy"
proj "$P" <<'EOF'
mb_dep_path("widgets", "../widgets");
EOF
drv "$P" ensure
check "path package with mbuild.toml" has "$S/last.out" "error: ../widgets has mbuild.toml, which is no longer read; it needs an mbuild.mettle"
P="$S/edit"
proj "$P" <<'EOF'
mb_dep("apilib", "v1.0.0");
EOF
drv "$P" get apilib@v1.1
check "get partial" has "$P/mbuild.mettle" 'mb_dep("apilib", "v1.1.0");'
check "get locks" [ "$(lockv "$P" apilib)" = "v1.1.0" ]
drv "$P" get zero
check "get latest adds" has "$P/mbuild.mettle" 'mb_dep("zero", "v0.2.0");'
drv "$P" update
check "update in line" [ "$(lockv "$P" apilib)" = "v1.2.0" ]
drv "$P" remove zero
check "remove" hasnt "$P/mbuild.mettle" '"zero"'
check "remove: unlocked" [ -z "$(lockline "$P" zero)" ]
drv "$P" tidy
check "tidy drops unused" hasnt "$P/mbuild.mettle" '"apilib"'
P="$S/apilib"
MAIN='export fn al_add(a: int32, b: int32) -> int32 { return a + b; }' proj "$P" </dev/null
drv "$P" breaks apilib v1.1.5
check "publish check: removed export" has "$S/last.out" "removed  fn al_mul"
check "publish check: new line" has "$S/last.out" "a breaking change needs a new line: publish v2.0.0"

echo "== get, update, --locked"
P="$S/getup"
MAIN='import "vecmath/vecmath";
fn main() -> int32 { return vm_one(); }' proj "$P" <<'EOF'
mb_dep("vecmath", "v0.1.0");
EOF
drv "$P" ensure
check "MVS: strutil v1.0.0 under vecmath v0.1.0" [ "$(lockv "$P" strutil)" = v1.0.0 ]
drv "$P" deps --tree
check "tree: vecmath with its C" has "$S/last.out" '`-- vecmath v0.1.0 (default) [native: C; c libs: m]'
check "tree: strutil under vecmath" has "$S/last.out" '    `-- strutil v1.0.0 (default)'
drv "$P" get vecmath@v0.2.0
check "get: mbuild.mettle" has "$P/mbuild.mettle" 'mb_dep("vecmath", "v0.2.0");'
check "get: strutil moves by MVS" [ "$(lockv "$P" strutil)" = v1.1.0 ]
check "get: says so" has "$S/last.out" "Updating strutil v1.0.0 -> v1.1.0"
cp "$P/mbuild.lock" "$S/getup.lock"
cp "$P/mbuild.mettle" "$S/getup.mettle"
drv "$P" get strutil@v2.0.0-rc.1
check "get pre-release of another line exits 1" code_is 1
check "get pre-release: conflict" has "$S/last.out" "error: strutil is required at incompatible versions:"
check "get pre-release: the lines" has "$S/last.out" "v2.0.0-rc.1 (line v2) by mbuild.mettle"
check "get pre-release: restored" has "$S/last.out" "Restored mbuild.mettle and mbuild.lock"
check "get pre-release: lock unchanged" cmp -s "$P/mbuild.lock" "$S/getup.lock"
check "get pre-release: mbuild.mettle unchanged" cmp -s "$P/mbuild.mettle" "$S/getup.mettle"
drv "$P" get strutil@v1
check "get @v1 takes the highest v1" has "$P/mbuild.mettle" 'mb_dep("strutil", "v1.1.0");'
drv "$P" get strutil@v1.9.0
check "unknown version fails" code_is 1
check "unknown version lists the versions" has "$S/last.out" "available versions: v1.0.0, v1.1.0, v2.0.0-rc.1"
# The compiler resolves imports through the mettle.deps mbuild writes.
printf 'import "std/io";\nimport "strutil/strutil";\nimport "vecmath/vecmath";\nfn main() -> int32 {\n  println(su_twice(vm_banner()));\n  println(su_version());\n  return 0;\n}\n' >"$P/check.mettle"
( cd "$P" && "$METTLE" --build check.mettle -o "$S/check" && "$S/check" ) >"$S/last.out" 2>&1
check "the compiler resolves through mettle.deps" has "$S/last.out" "vecmath!vecmath!"
check "and sees the selected strutil" has "$S/last.out" "strutil v1.1.0"
drv "$P" update
check "update names the new line" has "$S/last.out" "Newer vecmath v0.3.0 is a new compatibility line (v0.3): \`mbuild update --major vecmath\`"
check "update stays in the line" has "$P/mbuild.mettle" 'mb_dep("vecmath", "v0.2.0");'
drv "$P" update --major
check "update --major" has "$P/mbuild.mettle" 'mb_dep("vecmath", "v0.3.0");'
check "update --major: says so" has "$S/last.out" "Updating vecmath v0.2.0 -> v0.3.0"
drv "$P" update
check "then up to date" has "$S/last.out" "Checked dependencies are up to date"
cp "$P/mbuild.mettle" "$S/getup.mettle"
drv "$P" get zero --locked
check "get --locked fails" code_is 1
check "get --locked says why" has "$S/last.out" "--locked forbids it"
check "get --locked leaves mbuild.mettle" cmp -s "$P/mbuild.mettle" "$S/getup.mettle"
drv "$P" ensure --locked
check "ensure --locked passes when nothing changes" code_is 0
drv "$P" why nothere
check "why of a non-dependency" has "$S/last.out" "'nothere' is not a dependency of this project (with two arguments, \`mbuild why A B\` asks the compiler)"
rm -rf "$P/.mbuild"
MBUILD_HOME="$S/empty-home" drv "$P" ensure --offline
check "offline with an empty cache fails" code_is 1

echo "== path packages"
L="$S/mylib"
proj "$L" <<'EOF'
mb_dep("zero", "v0.1.0");
EOF
rm -rf "$L/src"
printf 'import "zero/zero";\nexport fn ml() -> int32 { return z_one(); }\n' >"$L/mylib.mettle"
P="$S/pathapp"
MAIN='import "std/io";
import "mylib/mylib";
fn main() -> int32 { println("ml={ml()}"); return 0; }' proj "$P" <<'EOF'
mb_dep_path("mylib", "../mylib");
EOF
drv "$P" ensure
check "path package: ensure" code_is 0
check "path package: DepModule" has "$S/last.out" "MOD mylib   registry= path=1 man=1"
check "its dependencies join the graph" [ "$(lockv "$P" zero)" = v0.1.0 ]
check "root mettle.deps names it" has "$P/mettle.deps" "mylib=../mylib"
check "it gets a mettle.deps" has "$L/mettle.deps" "zero=../pathapp/.mbuild/deps/zero"
( cd "$P" && "$METTLE" --build src/main.mettle -o "$S/pathapp.bin" && "$S/pathapp.bin" ) >"$S/last.out" 2>&1
check "path package: the program runs" has "$S/last.out" "ml=1"

echo "== mettle.deps lines mbuild does not manage"
P="$S/unmanaged"
proj "$P" </dev/null
mkdir -p "$S/foo"
printf 'export fn f5() -> int32 { return 5; }\n' >"$S/foo/foo.mettle"
drv "$P" ensure
echo 'foo=../foo' >>"$P/mettle.deps"
drv "$P" ensure
check "unmanaged line warning" has "$S/last.out" "warning: mettle.deps:5: foo=../foo is not managed by mbuild (its dependencies and C code are ignored)"
check "unmanaged line help" has "$S/last.out" 'help: run mbuild tidy to move it into mbuild.mettle as mb_dep_path("foo", "../foo");'
drv "$P" adopt
check "adopt" has "$S/last.out" "Adopted foo = ../foo from mettle.deps"
check "adopt writes mb_dep_path" has "$P/mbuild.mettle" 'mb_dep_path("foo", "../foo");'
drv "$P" ensure
check "adopted: a path package" has "$S/last.out" "MOD foo   registry= path=1 man=0"
check "adopted: no warning" hasnt "$S/last.out" "not managed"

echo "== with mbuild"
if [ -z "${MB:-}" ]; then
  "$METTLE" --build "$here/src/main.mettle" -o "$S/mbuild" >"$S/mbuild.log" 2>&1 || { cat "$S/mbuild.log"; exit 1; }
  MB="$S/mbuild"
fi
mb() { (cd "$1" && shift && "$MB" "$@") >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }
P="$S/b-app"
MAIN='import "strutil/strutil";
import "vecmath/vecmath";
fn main() -> int32 { return 0; }' proj "$P" <<'EOF'
mb_dep("vecmath", "v0.2.0");
EOF
mb "$P" build
check "build: auto-add" has "$S/last.out" "Adding strutil v1.1.0 (registry default)"
mb "$P" build -v
check "build: second is Fresh" has "$S/last.out" "Fresh"
check "build: no resolving" hasnt "$S/last.out" "Resolving"
P="$S/b-nosuch"
MAIN='import "nosuch/x";
fn main() -> int32 { return 0; }' proj "$P" </dev/null
mb "$P" build
check "build: E0006" has "$S/last.out" "E0006"
check "build: no registry note" has "$S/last.out" "no registry has a package named nosuch"

echo
echo "deps: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
