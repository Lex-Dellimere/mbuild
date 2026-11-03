#!/bin/sh
# deps_test.sh: end-to-end tests of src/deps.mettle and src/git.mettle through
# tests/deps_driver.mettle, against the local git fixtures.
#
#   tests/deps_test.sh            Linux driver (built with the head compiler)
#   tests/deps_test.sh --wine     also run the Windows driver under wine
#   DRIVER_METTLE=path/to/mettle  build the Linux driver with another compiler
#                                 (the test programs are always built with head)
#
# Uses /tmp/opencode/deps_test as scratch space; MBUILD_HOME points there, so
# ~/.mbuild is never touched.
#
# Under wine: the project directory and MBUILD_HOME are given in Windows form
# (Z:/tmp/...), because the Windows file APIs would put a bare /tmp/... on drive
# C:. MBUILD_GIT_BASE is given in Linux form (/tmp/...): git is a host program
# there, and mbuild passes a URL that starts with `/` to it unchanged (a
# Z:/... form works as well; it is converted like any other path).

set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
HEAD="${METTLE_HEAD:-$here/../Mettle/bin/mettle}"
W017="${METTLE_W017:-$HOME/.mbuild/toolchains/v0.17.0/windows/mettle.exe}"
S=/tmp/opencode/deps_test
rm -rf "$S"
mkdir -p "$S"
export WINEDEBUG=-all

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -40; }
check() { # name, command...
  name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name" "$(cat "$S/last.out" 2>/dev/null)"; fi
}
has() { grep -q -- "$2" "$1"; }
hasnt() { ! grep -q -- "$2" "$1"; }

echo "== building the driver"
"${DRIVER_METTLE:-$HEAD}" --build "$here/tests/deps_driver.mettle" -o "$S/drv" >"$S/build.log" 2>&1 || { cat "$S/build.log"; exit 1; }
D="$S/drv"

F="$S/fx"
"$here/tests/fixtures/make-fixtures.sh" "$F" >/dev/null
export MBUILD_HOME="$S/home"
export MBUILD_GIT_BASE="$F/gitbase"
A="$F/app"
G="$F/gitbase/github.com/demo"

run() { # dir command args... -> $S/last.out (stdout+stderr), $S/last.code
  "$D" "$@" >"$S/last.out" 2>&1
  echo $? >"$S/last.code"
}
code_is() { [ "$(cat "$S/last.code")" = "$1" ]; }
lockv() { awk -v m="$2" '$1 == m { print $2 }' "$1/mbuild.lock"; }
lockc() { awk -v m="$2" '$1 == m { print $3 }' "$1/mbuild.lock"; }
tagc() { git -C "$G/$1" rev-parse "$2^{commit}"; }
# The mirror of github.com/demo/$1 fetched through MBUILD_GIT_BASE (keyed by URL).
mir() { ls -d "${2:-$MBUILD_HOME}/git/github.com/demo/$1"@*.git 2>/dev/null | head -1; }

echo "== fresh ensure"
run "$A" ensure --verbose
check "verbose shows the git commands it runs" has "$S/last.out" "advice.detachedHead=false clone -q --mirror"
check "fresh ensure exits 0" code_is 0
check "fresh ensure fetches vecmath" has "$S/last.out" "Fetching github.com/demo/vecmath"
check "fresh ensure fetches strutil" has "$S/last.out" "Fetching github.com/demo/strutil"
check "lock: vecmath v0.1.0" [ "$(lockv "$A" github.com/demo/vecmath)" = v0.1.0 ]
check "lock: strutil v1.0.0 (MVS)" [ "$(lockv "$A" github.com/demo/strutil)" = v1.0.0 ]
check "lock: strutil commit = tag" [ "$(lockc "$A" github.com/demo/strutil)" = "$(tagc strutil v1.0.0)" ]
check "lock has requirements line" has "$A/mbuild.lock" "^# requirements "
check "mettle.deps block" has "$A/mettle.deps" "^github.com=./.mbuild/deps/github.com$"
check "checkout marker" [ "$(head -1 "$A/.mbuild/deps/github.com/demo/vecmath/.mbuild-commit")" = "$(tagc vecmath v0.1.0)" ]
check "checkout has files" [ -f "$A/.mbuild/deps/github.com/demo/vecmath/csrc/vec.c" ]
check "mirror exists (keyed by URL)" [ -f "$(mir strutil)/HEAD" ]
check "no unkeyed mirror for a non-default URL" [ ! -d "$MBUILD_HOME/git/github.com/demo/strutil.git" ]
check "git runs with BatchMode ssh" has "$S/last.out" "GIT_SSH_COMMAND=ssh -o BatchMode=yes"
check "no lock left behind" [ -z "$(ls -d "$MBUILD_HOME"/git/github.com/demo/*.lock 2>/dev/null)" ]
check "checkout gets its own mettle.deps" has "$A/.mbuild/deps/github.com/demo/vecmath/mettle.deps" "^github.com=../..$"
check "ensure lists modules" has "$S/last.out" "^MOD github.com/demo/vecmath v0.1.0 .* man=1"

echo "== fast path"
run "$A" ensure --verbose
check "second ensure exits 0" code_is 0
check "second ensure runs no git" hasnt "$S/last.out" "advice.detachedHead"
check "second ensure says unchanged" has "$S/last.out" "lock unchanged"
check "second ensure prints no Resolving" hasnt "$S/last.out" "Resolving"
printf '# a user line\nfoo=./foo\n' >>"$A/mettle.deps"
run "$A" ensure
check "user lines in mettle.deps kept" has "$A/mettle.deps" "^foo=./foo$"
check "block still present" has "$A/mettle.deps" "^github.com=./.mbuild/deps/github.com$"

echo "== deps --tree"
run "$A" deps --tree
check "tree shows vecmath native" has "$S/last.out" "github.com/demo/vecmath v0.1.0 \[native: C"
check "tree shows strutil under vecmath" has "$S/last.out" "    \`-- github.com/demo/strutil v1.0.0"
run "$A" deps
check "flat list" has "$S/last.out" "^github.com/demo/strutil v1.0.0"

echo "== get: MVS"
run "$A" get github.com/demo/vecmath@v0.2.0
check "get exits 0" code_is 0
check "manifest: vecmath v0.2.0" has "$A/mbuild.toml" '"github.com/demo/vecmath" = "v0.2.0"'
check "lock: vecmath v0.2.0" [ "$(lockv "$A" github.com/demo/vecmath)" = v0.2.0 ]
check "lock: strutil moved to v1.1.0" [ "$(lockv "$A" github.com/demo/strutil)" = v1.1.0 ]
check "prints Updating strutil" has "$S/last.out" "Updating github.com/demo/strutil v1.0.0 -> v1.1.0"
check "strutil checkout moved" [ "$(head -1 "$A/.mbuild/deps/github.com/demo/strutil/.mbuild-commit")" = "$(tagc strutil v1.1.0)" ]

echo "== get: explicit pre-release, partial version, unknown version"
# DESIGN.md 12.3: v2.0.0-rc.1 (line v2) and vecmath's v1.1.0 (line v1) conflict.
cp "$A/mbuild.lock" "$S/lock.before"
run "$A" get github.com/demo/strutil@v2.0.0-rc.1
check "get pre-release of another line exits 1" code_is 1
check "get pre-release: conflict error" has "$S/last.out" "github.com/demo/strutil is required at incompatible versions:"
check "get pre-release: lines named" has "$S/last.out" "v2.0.0-rc.1 (line v2) by mbuild.toml"
check "get pre-release: replace help" has "$S/last.out" '"github.com/demo/strutil" = { version = "v2.0.0-rc.1" }'
check "get pre-release: lock unchanged" cmp -s "$A/mbuild.lock" "$S/lock.before"
check "get pre-release: mbuild.toml restored" hasnt "$A/mbuild.toml" '"github.com/demo/strutil"'
check "get pre-release: says it restored" has "$S/last.out" "Restored mbuild.toml and mbuild.lock"
run "$A" get github.com/demo/strutil@v1
check "get @v1 picks the highest v1" has "$A/mbuild.toml" '"github.com/demo/strutil" = "v1.1.0"'
check "lock: strutil back to v1.1.0" [ "$(lockv "$A" github.com/demo/strutil)" = v1.1.0 ]
run "$A" get github.com/demo/strutil@v9.9.9
check "unknown version fails" code_is 1
check "unknown version lists tags" has "$S/last.out" "available versions: v1.0.0, v1.1.0, v2.0.0-rc.1"

echo "== auto-add (branch only module)"
run "$A" auto github.com/demo/nomanifest github.com/demo/vecmath
check "add-missing reports added" has "$S/last.out" "^ADDED 1"
check "one Adding line in one process" [ "$(grep -c Adding "$S/last.out")" = 1 ]
check "add-missing prints Adding" has "$S/last.out" "Adding github.com/demo/nomanifest main"
check "manifest: nomanifest = main" has "$A/mbuild.toml" '"github.com/demo/nomanifest" = "main"'
run "$A" add-missing github.com/demo/nomanifest
check "add-missing is idempotent" has "$S/last.out" "^ADDED 0"
run "$A" ensure
check "lock: nomanifest main" [ "$(lockv "$A" github.com/demo/nomanifest)" = main ]
check "nomanifest has no manifest" has "$S/last.out" "^MOD github.com/demo/nomanifest main .* man=0"
check "nothing to add on the next ensure" [ "$(grep -c Adding "$S/last.out")" = 0 ]

echo "== the compiler resolves through mettle.deps"
cat >"$A/src/check.mettle" <<'EOF'
import "std/io";
import "github.com/demo/strutil/strutil";
import "github.com/demo/nomanifest/greet";

fn main() -> int32 {
  println(su_twice(su_shout(greet("deps"))));
  println(su_version());
  return 0;
}
EOF
(cd "$A" && "$HEAD" --build src/check.mettle -o "$S/check" >"$S/last.out" 2>&1)
check "check.mettle compiles" [ -x "$S/check" ]
"$S/check" >"$S/last.out" 2>&1
check "check.mettle runs" has "$S/last.out" "^hello, deps!hello, deps!$"
check "check.mettle sees strutil v1.1.0" has "$S/last.out" "^strutil v1.1.0$"

echo "== branch pins move only on update"
nm_old="$(lockc "$A" github.com/demo/nomanifest)"
printf 'export fn greet2() -> string {\n  return "two";\n}\n' >"$G/nomanifest/greet2.mettle"
git -C "$G/nomanifest" add -A && git -C "$G/nomanifest" commit -q -m two
nm_new="$(git -C "$G/nomanifest" rev-parse HEAD)"
rm -f "$A/.mbuild/deps.stamp"
run "$A" ensure
check "branch stays pinned on ensure" [ "$(lockc "$A" github.com/demo/nomanifest)" = "$nm_old" ]
run "$A" update github.com/demo/nomanifest
check "update exits 0" code_is 0
check "update moves the branch pin" [ "$(lockc "$A" github.com/demo/nomanifest)" = "$nm_new" ]
check "update prints the move" has "$S/last.out" "Updating github.com/demo/nomanifest main ("

echo "== tidy"
run "$A" tidy github.com/demo/vecmath github.com/demo/nomanifest
check "tidy exits 0" code_is 0
check "tidy removes strutil requirement" hasnt "$A/mbuild.toml" '"github.com/demo/strutil"'
check "tidy keeps vecmath" has "$A/mbuild.toml" '"github.com/demo/vecmath"'
check "tidy prints Removing" has "$S/last.out" "Removing github.com/demo/strutil"
check "strutil stays locked (transitive)" [ "$(lockv "$A" github.com/demo/strutil)" = v1.1.0 ]
run "$A" tidy github.com/demo/vecmath github.com/demo/nomanifest github.com/demo/strutil
check "tidy adds a missing import" has "$A/mbuild.toml" '"github.com/demo/strutil" = "v1.1.0"'

echo "== remove"
run "$A" remove github.com/demo/nomanifest
check "remove exits 0" code_is 0
check "remove drops the requirement" hasnt "$A/mbuild.toml" "nomanifest"
check "remove drops the lock entry" hasnt "$A/mbuild.lock" "nomanifest"
check "remove drops the checkout" [ ! -d "$A/.mbuild/deps/github.com/demo/nomanifest" ]
run "$A" remove github.com/demo/nothere
check "remove of an unknown module fails" code_is 1

echo "== update raises minimums"
run "$A" get github.com/demo/vecmath@v0.1.0
run "$A" remove github.com/demo/strutil
check "after downgrade: strutil v1.0.0" [ "$(lockv "$A" github.com/demo/strutil)" = v1.0.0 ]
run "$A" update
check "update exits 0" code_is 0
check "update stays in the v0.1 line" has "$A/mbuild.toml" '"github.com/demo/vecmath" = "v0.1.0"'
check "update names the new line" has "$S/last.out" "Newer github.com/demo/vecmath v0.2.0 is a new compatibility line (v0.2)"
run "$A" update --major github.com/demo/vecmath
check "update --major exits 0" code_is 0
check "update --major raises vecmath" has "$A/mbuild.toml" '"github.com/demo/vecmath" = "v0.2.0"'
check "update prints vecmath" has "$S/last.out" "Updating github.com/demo/vecmath v0.1.0 -> v0.2.0"
check "update moves strutil by MVS" [ "$(lockv "$A" github.com/demo/strutil)" = v1.1.0 ]
run "$A" update
check "second update: up to date" has "$S/last.out" "up to date"

echo "== --locked"
cp "$A/mbuild.toml" "$S/toml.bak"
run "$A" get github.com/demo/strutil@v1.0.0 --locked
check "get --locked fails" code_is 1
check "get --locked says why" has "$S/last.out" "locked"
check "get --locked leaves mbuild.toml" cmp -s "$A/mbuild.toml" "$S/toml.bak"
printf '"github.com/demo/nomanifest" = "main"\n' >>"$A/mbuild.toml"
run "$A" ensure --locked
check "ensure --locked refuses a lock change" code_is 1
check "ensure --locked message" has "$S/last.out" "mbuild.lock is out of date"
cp "$S/toml.bak" "$A/mbuild.toml"
run "$A" add-missing github.com/demo/strutil --locked
check "add-missing --locked fails" code_is 1
check "add-missing --locked says why" has "$S/last.out" "--locked forbids adding"
cp "$S/toml.bak" "$A/mbuild.toml"
run "$A" ensure --locked
check "ensure --locked passes when nothing changes" code_is 0

echo "== lock reproducibility (fetch, then --offline)"
cp "$A/mbuild.lock" "$S/lock.bak"
rm -rf "$A/.mbuild" "$MBUILD_HOME"
run "$A" fetch
check "fetch exits 0" code_is 0
check "fetch clones" has "$S/last.out" "Fetching github.com/demo/vecmath"
rm -rf "$A/.mbuild"
mv "$F/gitbase" "$F/gitbase.away"
run "$A" ensure --offline
check "offline ensure exits 0" code_is 0
check "offline ensure keeps the lock" cmp -s "$A/mbuild.lock" "$S/lock.bak"
check "offline checkout = locked commit" [ "$(head -1 "$A/.mbuild/deps/github.com/demo/strutil/.mbuild-commit")" = "$(lockc "$A" github.com/demo/strutil)" ]
rm -rf "$(mir strutil)" "$A/.mbuild"
run "$A" ensure --offline
check "offline without a mirror fails" code_is 1
check "offline failure says fetch" has "$S/last.out" "mbuild fetch"
mv "$F/gitbase.away" "$F/gitbase"

echo "== alias and path packages"
mkdir -p "$F/mylib" "$F/app2/src"
cat >"$F/mylib/mbuild.toml" <<'EOF'
[package]
name = "mylib"

[dependencies]
"github.com/demo/nomanifest" = "main"
EOF
cat >"$F/mylib/lib.mettle" <<'EOF'
import "github.com/demo/nomanifest/greet";

export fn ml_hello() -> string {
  return greet("mylib");
}
EOF
cat >"$F/app2/mbuild.toml" <<'EOF'
[package]
name = "app2"

[dependencies]
su = { module = "github.com/demo/strutil", version = "v1.0.0" }
mylib = { path = "../mylib" }
EOF
cat >"$F/app2/src/main.mettle" <<'EOF'
import "std/io";
import "su/strutil";
import "mylib/lib";

fn main() -> int32 {
  println(su_shout(ml_hello()) + " " + su_version());
  return 0;
}
EOF
run "$F/app2" ensure
check "app2 ensure exits 0" code_is 0
check "alias published" has "$F/app2/mettle.deps" "^su=./.mbuild/deps/github.com/demo/strutil$"
check "path package published" has "$F/app2/mettle.deps" "^mylib=../mylib$"
check "host published" has "$F/app2/mettle.deps" "^github.com=./.mbuild/deps/github.com$"
check "path package's deps join the graph" [ "$(lockv "$F/app2" github.com/demo/nomanifest)" = main ]
check "DepModule for the path package" has "$S/last.out" "^MOD mylib   alias=mylib path=1 man=1"
check "DepModule alias" has "$S/last.out" "^MOD github.com/demo/strutil v1.0.0 .* alias=su path=0"
(cd "$F/app2" && "$HEAD" --build src/main.mettle -I .mbuild/deps -o "$S/app2" >"$S/last.out" 2>&1)
check "app2 compiles" [ -x "$S/app2" ]
"$S/app2" >"$S/last.out" 2>&1
check "app2 runs" has "$S/last.out" "^hello, mylib! strutil v1.0.0$"
check "path package gets a mettle.deps" has "$F/mylib/mettle.deps" "^github.com=../app2/.mbuild/deps/github.com$"
run "$F/app2" get su@v1.1.0
check "get by alias key" has "$F/app2/mbuild.toml" 'su = { module = "github.com/demo/strutil", version = "v1.1.0" }'
run "$F/app2" remove su
check "remove by alias key" hasnt "$F/app2/mbuild.toml" "^su ="
check "alias line gone" hasnt "$F/app2/mettle.deps" "^su="
run "$F/app2" get su@v1.0.0
check "get of an unknown non-module name fails" code_is 1
printf 'su = { module = "github.com/demo/strutil", version = "v1.0.0" }\n' >>"$F/app2/mbuild.toml"
run "$F/app2" ensure

echo "== a moved tag keeps the locked commit"
mkdir -p "$F/app7"
printf '[package]\nname = "app7"\n\n[dependencies]\n"github.com/demo/vecmath" = "v0.1.0"\n' >"$F/app7/mbuild.toml"
run "$F/app7" ensure
check "app7 locks strutil v1.0.0 (transitive)" [ "$(lockv "$F/app7" github.com/demo/strutil)" = v1.0.0 ]
old="$(lockc "$F/app2" github.com/demo/strutil)"
check "app2 locks strutil v1.0.0" [ "$(lockv "$F/app2" github.com/demo/strutil)" = v1.0.0 ]
git -C "$G/strutil" checkout -q -b moved v1.0.0
echo "// moved" >>"$G/strutil/strutil.mettle"
git -C "$G/strutil" commit -q -am moved
git -C "$G/strutil" tag -f v1.0.0 >/dev/null 2>&1
git -C "$G/strutil" checkout -q main
check "the tag really moved" [ "$(tagc strutil v1.0.0)" != "$old" ]
rm -rf "$(mir strutil)" "$F/app2/.mbuild"
run "$F/app2" ensure
check "ensure after moved tag exits 0" code_is 0
check "lock keeps the old commit" [ "$(lockc "$F/app2" github.com/demo/strutil)" = "$old" ]
check "checkout is the old commit" [ "$(head -1 "$F/app2/.mbuild/deps/github.com/demo/strutil/.mbuild-commit")" = "$old" ]
check "moved tag warns" has "$S/last.out" "tag v1.0.0 of github.com/demo/strutil moved upstream (${old%"${old#???????}"} -> "
check "moved tag names the fix" has "$S/last.out" "keeping ${old%"${old#???????}"}; run \`mbuild update github.com/demo/strutil\` to take"
new="$(tagc strutil v1.0.0)"
rm -f "$F/app7/.mbuild/deps.stamp"
run "$F/app7" ensure
check "app7 ensure keeps the locked commit" [ "$(lockc "$F/app7" github.com/demo/strutil)" = "$old" ]
check "app7 ensure warns" has "$S/last.out" "moved upstream"
run "$F/app7" update github.com/demo/strutil
check "update takes the moved tag" [ "$(lockc "$F/app7" github.com/demo/strutil)" = "$new" ]
check "update says the tag moved" has "$S/last.out" "Updating github.com/demo/strutil v1.0.0 (tag moved upstream: "
check "update keeps the version" [ "$(lockv "$F/app7" github.com/demo/strutil)" = v1.0.0 ]

echo "== a repository that does not exist"
mkdir -p "$F/app3"
printf '[package]\nname = "app3"\n\n[dependencies]\n"github.com/demo/nope" = "v1.0.0"\n' >"$F/app3/mbuild.toml"
run "$F/app3" ensure
check "missing repo fails" code_is 1
check "missing repo names the URL" has "$S/last.out" "from $F/gitbase/github.com/demo/nope"
check "missing repo hints MBUILD_GIT_BASE" has "$S/last.out" "MBUILD_GIT_BASE="
check "missing repo leaves no mirror" [ -z "$(ls -d "$MBUILD_HOME"/git/github.com/demo/nope* 2>/dev/null)" ]
MBUILD_GIT_BASE= "$D" "$F/app3" get example.invalid/x/y --verbose >"$S/last.out" 2>&1
check "https URL is tried without MBUILD_GIT_BASE" has "$S/last.out" "https://example.invalid/x/y"
check "the default https mirror is unkeyed" has "$S/last.out" "clone -q --mirror https://example.invalid/x/y .*/git/example.invalid/x/y.git.new"
# DESIGN.md 12.10: an unresolvable host is a network failure.
check "unresolvable host: network error" has "$S/last.out" "the network is unavailable"

echo "== no dependencies"
mkdir -p "$F/app4"
printf '[package]\nname = "app4"\n' >"$F/app4/mbuild.toml"
run "$F/app4" ensure
check "no deps: exit 0" code_is 0
check "no deps: no lock" [ ! -f "$F/app4/mbuild.lock" ]
check "no deps: no mettle.deps" [ ! -f "$F/app4/mettle.deps" ]
check "no deps: no Resolving" hasnt "$S/last.out" "Resolving"

# A fresh project depending on vecmath v0.1.0 (so strutil v1.0.0 is selected
# while v1.1.0 is the latest), with extra manifest lines.
mkapp() { # dir extra-dependency-lines
  mkdir -p "$1/src"
  printf '[package]\nname = "%s"\n\n[dependencies]\n"github.com/demo/vecmath" = "v0.1.0"\n%s' "$(basename "$1")" "${2:-}" >"$1/mbuild.toml"
}

echo "== tidy: direct imports of selected modules, unused aliases and path packages"
mkdir -p "$F/unused"
printf '[package]\nname = "unused"\n' >"$F/unused/mbuild.toml"
mkapp "$F/app6" 'nm = { module = "github.com/demo/nomanifest", version = "main" }
un = { path = "../unused" }
'
run "$F/app6" ensure
check "app6 ensure exits 0" code_is 0
check "app6 selects strutil v1.0.0" [ "$(lockv "$F/app6" github.com/demo/strutil)" = v1.0.0 ]
run "$F/app6" tidy github.com/demo/vecmath github.com/demo/strutil
check "tidy exits 0" code_is 0
check "tidy adds a transitive import at the selected version" has "$F/app6/mbuild.toml" '"github.com/demo/strutil" = "v1.0.0"'
check "tidy says it was selected" has "$S/last.out" "Adding github.com/demo/strutil v1.0.0 (already selected)"
check "tidy does not upgrade it" [ "$(lockv "$F/app6" github.com/demo/strutil)" = v1.0.0 ]
check "tidy removes an unused alias" hasnt "$F/app6/mbuild.toml" "^nm ="
check "tidy removes an unused path package" hasnt "$F/app6/mbuild.toml" "^un ="
check "tidy prints the alias it removes" has "$S/last.out" "Removing nm"
check "the alias's module leaves the lock" hasnt "$F/app6/mbuild.lock" "nomanifest"
mkapp "$F/app6b" 'nm = { module = "github.com/demo/nomanifest", version = "main" }
'
run "$F/app6b" ensure
run "$F/app6b" tidy github.com/demo/vecmath nm github.com/demo/nomanifest
check "tidy keeps a used alias" has "$F/app6b/mbuild.toml" "^nm = "
check "a module required through an alias is not added again" [ "$(grep -c nomanifest "$F/app6b/mbuild.toml")" = 1 ]
mkapp "$F/app6c"
run "$F/app6c" auto github.com/demo/strutil
check "auto-add of a selected module keeps its version" has "$F/app6c/mbuild.toml" '"github.com/demo/strutil" = "v1.0.0"'
check "auto-add keeps the lock" [ "$(lockv "$F/app6c" github.com/demo/strutil)" = v1.0.0 ]

echo "== aliases are scoped to the package that declares them"
mkdir -p "$F/mylib5" "$F/app5/src"
cat >"$F/mylib5/mbuild.toml" <<'EOF'
[package]
name = "mylib5"

[dependencies]
su = { module = "github.com/demo/strutil", version = "v1.0.0" }
EOF
cat >"$F/mylib5/lib.mettle" <<'EOF'
import "su/strutil";

export fn ml_hello() -> string {
  return su_shout("mylib5");
}
EOF
cat >"$F/app5/mbuild.toml" <<'EOF'
[package]
name = "app5"

[dependencies]
mylib5 = { path = "../mylib5" }
EOF
cat >"$F/app5/src/main.mettle" <<'EOF'
import "std/io";
import "mylib5/lib";

fn main() -> int32 {
  println(ml_hello());
  return 0;
}
EOF
run "$F/app5" ensure
check "app5 ensure exits 0" code_is 0
check "root block has no dependency aliases" hasnt "$F/app5/mettle.deps" "^su="
check "root block publishes the path package" has "$F/app5/mettle.deps" "^mylib5=../mylib5$"
check "path package block holds its alias" has "$F/mylib5/mettle.deps" "^su=../app5/.mbuild/deps/github.com/demo/strutil$"
check "path package block holds the hosts" has "$F/mylib5/mettle.deps" "^github.com=../app5/.mbuild/deps/github.com$"
rm -f "$S/app5"
(cd "$F/app5" && "$HEAD" --build src/main.mettle -o "$S/app5" >"$S/last.out" 2>&1)
check "app5 compiles with plain mettle (no -I)" [ -x "$S/app5" ]
"$S/app5" >"$S/last.out" 2>&1
check "app5 runs" has "$S/last.out" "^mylib5!$"
printf '# mine\n' >>"$F/mylib5/mettle.deps"
run "$F/app5" ensure
check "user lines in a path package's mettle.deps kept" has "$F/mylib5/mettle.deps" "^# mine$"

echo "== mirrors are keyed by URL"
mkapp "$F/app8" '"github.com/demo/strutil" = { version = "v1.0.0", url = "file://'"$G"'/strutil" }
'
run "$F/app8" ensure
check "app8 ensure exits 0" code_is 0
check "two mirrors for two URLs" [ "$(ls -d "$MBUILD_HOME"/git/github.com/demo/strutil@*.git | wc -l)" = 2 ]
check "the other project's mirror is untouched" [ -f "$(mir strutil)/HEAD" ]

echo "== --force restores a damaged checkout"
rm -f "$F/app8/.mbuild/deps/github.com/demo/strutil/strutil.mettle"
echo "// edited" >>"$F/app8/.mbuild/deps/github.com/demo/vecmath/vecmath.mettle"
run "$F/app8" ensure
check "ensure without --force does not notice" [ ! -f "$F/app8/.mbuild/deps/github.com/demo/strutil/strutil.mettle" ]
run "$F/app8" ensure --force
check "ensure --force exits 0" code_is 0
check "ensure --force restores a deleted file" [ -f "$F/app8/.mbuild/deps/github.com/demo/strutil/strutil.mettle" ]
check "ensure --force restores an edited file" hasnt "$F/app8/.mbuild/deps/github.com/demo/vecmath/vecmath.mettle" "// edited"
check "ensure --force rewrites the checkout's mettle.deps" [ -f "$F/app8/.mbuild/deps/github.com/demo/strutil/mettle.deps" ]
rm -f "$F/app8/.mbuild/deps/github.com/demo/strutil/strutil.mettle"
run "$F/app8" fetch --force
check "fetch --force restores it too" [ -f "$F/app8/.mbuild/deps/github.com/demo/strutil/strutil.mettle" ]

echo "== get accepts repository URLs"
for form in "https://github.com/demo/strutil" "http://github.com/demo/strutil/" "ssh://git@github.com/demo/strutil.git" "git@github.com:demo/strutil.git" "https://github.com/demo/strutil.git/@v1.0.0" "git@github.com:demo/strutil@v1.0.0"; do
  mkapp "$F/appg"
  run "$F/appg" get "$form"
  check "get $form" has "$F/appg/mbuild.toml" '^"github.com/demo/strutil" = "v1'
  rm -rf "$F/appg"
done

echo "== update --all"
mkdir -p "$F/mylib9"
printf '[package]\nname = "mylib9"\n\n[dependencies]\n"github.com/demo/strutil" = "v1.0.0"\n\n[link]\nlibs = ["z"]\n' >"$F/mylib9/mbuild.toml"
mkdir -p "$F/app9"
printf '[package]\nname = "app9"\n\n[dependencies]\nmylib9 = { path = "../mylib9" }\n' >"$F/app9/mbuild.toml"
run "$F/app9" ensure
check "app9 selects strutil v1.0.0" [ "$(lockv "$F/app9" github.com/demo/strutil)" = v1.0.0 ]
run "$F/app9" update
check "update leaves transitive modules" [ "$(lockv "$F/app9" github.com/demo/strutil)" = v1.0.0 ]
run "$F/app9" update --all
check "update --all exits 0" code_is 0
check "update --all raises a transitive module" [ "$(lockv "$F/app9" github.com/demo/strutil)" = v1.1.0 ]
check "update --all records it in mbuild.toml" has "$F/app9/mbuild.toml" '"github.com/demo/strutil" = "v1.1.0"'
check "update --all says so" has "$S/last.out" "Updating github.com/demo/strutil v1.0.0 -> v1.1.0"
run "$F/app9" update --all
check "second update --all: up to date" has "$S/last.out" "up to date"

echo "== deps lists native libraries"
run "$F/app9" deps
check "deps shows link libs" has "$S/last.out" "^mylib9 .*link libs: z"
run "$A" deps
check "deps shows c libs" has "$S/last.out" "^github.com/demo/vecmath v0.* .*\[native: C; c libs: m\]"

echo "== GIT_SSH_COMMAND set by the user is kept"
rm -f "$F/app9/.mbuild/deps.stamp"
GIT_SSH_COMMAND="ssh -i mykey" "$D" "$F/app9" update --verbose >"$S/last.out" 2>&1
check "user GIT_SSH_COMMAND not overridden" hasnt "$S/last.out" "BatchMode"

echo "== concurrent runs share one mirror"
CH="$S/chome"
for n in 1 2 3; do mkapp "$F/appc$n"; cp "$A/src/main.mettle" "$F/appc$n/src/"; done
for n in 1 2 3; do (MBUILD_HOME="$CH" "$D" "$F/appc$n" ensure >"$S/c$n.out" 2>&1; echo $? >"$S/c$n.code") & done
wait
for n in 1 2 3; do
  cp "$S/c$n.out" "$S/last.out"
  check "concurrent ensure $n exits 0" [ "$(cat "$S/c$n.code")" = 0 ]
  check "concurrent ensure $n locks strutil" [ "$(lockc "$F/appc$n" github.com/demo/strutil)" = "$(lockc "$F/app7" github.com/demo/strutil)" ]
done
check "one mirror per module" [ "$(ls -d "$CH"/git/github.com/demo/strutil*.git | wc -l)" = 1 ]
check "no lock or temp left" [ -z "$(ls -d "$CH"/git/github.com/demo/*.lock "$CH"/git/github.com/demo/*.new 2>/dev/null)" ]
check "the shared mirror is sound" git -C "$(mir strutil "$CH")" rev-parse -q --verify --quiet "refs/tags/v1.1.0^{commit}" >/dev/null

echo "== mirror locks: waiting and stale locks"
sm="$(mir strutil "$CH")"
lk="$sm.lock"
rm -rf "$sm" "$F/appc1/.mbuild"
mkdir "$lk"
(sleep 1; rmdir "$lk") &
MBUILD_HOME="$CH" "$D" "$F/appc1" ensure >"$S/last.out" 2>&1; echo $? >"$S/last.code"
wait
check "waits for a held lock" has "$S/last.out" "Waiting for another mbuild"
check "succeeds once it is released" code_is 0
rm -rf "$sm" "$F/appc1/.mbuild"
mkdir "$lk"
touch -d '20 minutes ago' "$lk"
MBUILD_HOME="$CH" "$D" "$F/appc1" ensure >"$S/last.out" 2>&1; echo $? >"$S/last.code"
check "breaks a stale lock" has "$S/last.out" "breaking the stale lock"
check "succeeds after breaking it" code_is 0
check "stale lock removed" [ ! -d "$lk" ]

if [ "${1:-}" = "--wine" ]; then
  echo "== wine"
  WD="$S/drv.exe"
  wine "$W017" --build "$(winepath -w "$here/tests/deps_driver.mettle" 2>/dev/null)" -o "$(winepath -w "$WD" 2>/dev/null)" >"$S/wbuild.log" 2>&1 || { cat "$S/wbuild.log"; }
  WF="$S/wfx"
  "$here/tests/fixtures/make-fixtures.sh" "$WF" >/dev/null
  WA="Z:$WF/app"
  wrun() { MBUILD_HOME="Z:$S/whome" MBUILD_GIT_BASE="$WF/gitbase" wine "$WD" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; tr -d '\r' <"$S/last.out" >"$S/last.tmp"; mv "$S/last.tmp" "$S/last.out"; }
  G="$WF/gitbase/github.com/demo"
  wrun "$WA" ensure
  check "wine: fresh ensure exits 0" code_is 0
  check "wine: fetches" has "$S/last.out" "Fetching github.com/demo/strutil"
  check "wine: mirror in MBUILD_HOME" [ -f "$(mir strutil "$S/whome")/HEAD" ]
  check "wine: no lock left behind" [ -z "$(ls -d "$S"/whome/git/github.com/demo/*.lock 2>/dev/null)" ]
  check "wine: checkout gets its own mettle.deps" has "$WF/app/.mbuild/deps/github.com/demo/vecmath/mettle.deps" "^github.com=../..$"
  check "wine: lock strutil v1.0.0" [ "$(lockc "$WF/app" github.com/demo/strutil)" = "$(tagc strutil v1.0.0)" ]
  check "wine: checkout marker" [ "$(head -1 "$WF/app/.mbuild/deps/github.com/demo/vecmath/.mbuild-commit")" = "$(tagc vecmath v0.1.0)" ]
  check "wine: mettle.deps" has "$WF/app/mettle.deps" "^github.com=./.mbuild/deps/github.com$"
  wrun "$WA" ensure --verbose
  check "wine: fast path exits 0" code_is 0
  check "wine: fast path runs no git" hasnt "$S/last.out" "advice.detachedHead"
  wrun "$WA" get github.com/demo/vecmath@v0.2.0
  check "wine: get exits 0" code_is 0
  check "wine: MVS strutil v1.1.0" [ "$(lockv "$WF/app" github.com/demo/strutil)" = v1.1.0 ]
  check "wine: vecmath v0.2.0" [ "$(lockv "$WF/app" github.com/demo/vecmath)" = v0.2.0 ]
  wrun "$WA" add-missing github.com/demo/nomanifest
  check "wine: auto-add branch module" has "$WF/app/mbuild.toml" '"github.com/demo/nomanifest" = "main"'
  wrun "$WA" ensure
  check "wine: nomanifest locked" [ "$(lockv "$WF/app" github.com/demo/nomanifest)" = main ]
  (cd "$WF/app" && "$HEAD" --build src/check.mettle -o "$S/wcheck" >/dev/null 2>&1) || true
  cp "$A/src/check.mettle" "$WF/app/src/check.mettle"
  (cd "$WF/app" && "$HEAD" --build src/check.mettle -o "$S/wcheck" >"$S/last.out" 2>&1)
  "$S/wcheck" >"$S/last.out" 2>&1
  check "wine-written mettle.deps compiles and runs" has "$S/last.out" "^strutil v1.1.0$"
  rm -f "$WF/app/.mbuild/deps/github.com/demo/strutil/strutil.mettle"
  wrun "$WA" ensure --force
  check "wine: --force restores a deleted file" [ -f "$WF/app/.mbuild/deps/github.com/demo/strutil/strutil.mettle" ]
  wrun "$WA" get git@github.com:demo/strutil.git@v1.0.0
  check "wine: get of an scp-style URL" has "$WF/app/mbuild.toml" '"github.com/demo/strutil" = "v1.0.0"'
  wsm="$(mir strutil "$S/whome")"
  rm -rf "$wsm" "$WF/app/.mbuild"
  mkdir "$wsm.lock"
  (sleep 2; rmdir "$wsm.lock") &
  wrun "$WA" ensure
  wait
  check "wine: waits for a held lock" has "$S/last.out" "Waiting for another mbuild"
  check "wine: succeeds once it is released" code_is 0
  check "wine: mirror re-made" [ -f "$wsm/HEAD" ]
  wrun "$WA" deps
  check "wine: deps shows c libs" has "$S/last.out" "c libs: m"
fi

echo
echo "$pass passed, $failed failed"
[ "$failed" = 0 ]
