#!/bin/sh
# mreg.sh: a registry in the Mettle project's format (DESIGN.md 13.9) through a path and
# http, end to end with a real mbuild: resolve, lock, fetch, verify, extract, build, run.
#   METTLE=dev-compiler sh tests/e2e/mreg.sh   (scratch: $MBTEST_TMP)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
S="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/mreg}"
rm -rf "$S"
mkdir -p "$S"
export LC_ALL=C NO_COLOR=1 METTLE
unset MBUILD_COLOR MBUILD_CURL MBUILD_TAR

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -30; }
check() { name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$S/last.out" 2>/dev/null)"; fi; }
has() { grep -qF -- "$1" "$S/last.out"; }
hasnt() { ! grep -qF -- "$1" "$S/last.out"; }
code_is() { [ "$(cat "$S/last.code")" = "$1" ]; }
mb() { "$MB" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }

echo "== mbuild and the fixture"
"$METTLE" --build "$here/src/main.mettle" -o "$S/mbuild" >"$S/build.log" 2>&1 || { cat "$S/build.log"; exit 1; }
MB="$S/mbuild"
sh "$here/tests/fixtures/make-mettle-registry.sh" "$S/fx" >/dev/null || exit 1
REG="$S/fx/mreg"
sha() { sha256sum "$REG/v1/archives/$1" | cut -c1-64; }

pid=""
trap 'kill $pid 2>/dev/null' EXIT
H=""
if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  (cd "$REG" && exec python3 -m http.server "$port" --bind 127.0.0.1 >"$S/http.log" 2>&1) &
  pid=$!
  i=0
  while [ $i -lt 50 ] && ! curl -fs "http://127.0.0.1:$port/v1/index.json" >/dev/null 2>&1; do sleep 0.1; i=$((i + 1)); done
  H="http://127.0.0.1:$port/"
else
  echo "note: http registry skipped (no python3 or curl)"
fi

# app DIR DEPS MAIN: a project with the mb_dep lines DEPS and src/main.mettle MAIN
app() {
  rm -rf "$1"; mkdir -p "$1/src"
  printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("%s", "0.1.0");\n}\n\nfn deps() {\n%s}\n' "$(basename "$1")" "$2" >"$1/mbuild.mettle"
  printf '%s\n' "$3" >"$1/src/main.mettle"
}
MAIN='import "std/io";
import "greet/greet";
import "textkit/extra";

fn main() -> int32 {
  println(gr_hello("bob"));
  println(tk_twice(tk_version()));
  return 0;
}'
DEPS='  mb_dep("greet", "1.0.0");
  mb_dep("textkit", "1.1.0");
'

for form in path http; do
  if [ $form = path ]; then URL="$REG"; else URL="$H"; [ -n "$URL" ] || continue; fi
  echo "== $form"
  export MBUILD_HOME="$S/home-$form" MBUILD_REGISTRY="$URL"
  W="$S/$form"
  app "$W/app" "$DEPS" "$MAIN"
  cd "$W/app" || exit 1
  mb run
  check "run ($form)" eval 'code_is 0 && grep -qx "hello bob!" "$S/last.out" && grep -qx "textkit 1.1.0textkit 1.1.0" "$S/last.out"' 
  check "fetches the selected versions ($form)" eval 'has "Fetching greet v1.0.0 (default)" && has "Fetching textkit v1.1.0 (default)"'
  check "lock: MVS picks textkit v1.1.0 over greet's 1.0.0 ($form)" sh -c '[ "$(grep -v "^#" mbuild.lock)" = "$(printf "greet v1.0.0 default sha256:%s\ntextkit v1.1.0 default sha256:%s" "$1" "$2")" ]' "$S" "$(sha greet-1.0.0.tar)" "$(sha textkit-1.1.0.tar)"
  check "extracted with mettle.package ($form)" sh -c '[ -f .mbuild/deps/greet/mettle.package ] && [ -f .mbuild/deps/greet/greet.mettle ] && grep -qx "greet v1.0.0 sha256:$0 default" .mbuild/deps/greet/.mbuild-pkg' "$(sha greet-1.0.0.tar)"
  check "greet's mettle.deps maps textkit ($form)" grep -qx "textkit=../textkit" .mbuild/deps/greet/mettle.deps
  check "kind cached as json ($form)" sh -c 'cat "$MBUILD_HOME"/registry/default@*/kind | grep -qx json'
  mb deps
  check "deps lists the registry ($form)" has "greet v1.0.0 (default)"

  # the cache serves a second project offline; a cold cache does not
  app "$W/app2" "$DEPS" "$MAIN"
  cd "$W/app2" || exit 1
  mb --offline run
  check "offline from the cache ($form)" eval 'code_is 0 && has "hello bob!"'
  app "$W/app3" "$DEPS" "$MAIN"
  cd "$W/app3" || exit 1
  MBUILD_HOME="$S/cold-$form" mb --offline build
  check "offline with a cold cache ($form)" eval 'code_is 1 && has "--offline forbids fetching it"'

  # an archive whose bytes do not match the index
  app "$W/badapp" '  mb_dep("badsha", "1.0.0");
' 'import "badsha/badsha";
fn main() -> int32 {
  return bs_x() - 1;
}'
  cd "$W/badapp" || exit 1
  mb build
  check "bad sha refused ($form)" eval 'code_is 1 && has "error: badsha v1.0.0 from registry default does not match its index" && has "sha256:0000000000000000..."'
  check "bad sha leaves nothing ($form)" sh -c '[ ! -e .mbuild/deps/badsha ] && ! ls "$MBUILD_HOME"/registry/default@*/v1/archives/badsha-1.0.0.tar 2>/dev/null'

  # a symlink member, a yanked version
  app "$W/evilapp" '  mb_dep("evil", "1.0.0");
' 'import "evil/evil";
fn main() -> int32 {
  return ev_x() - 1;
}'
  cd "$W/evilapp" || exit 1
  mb build
  check "symlink member refused ($form)" eval 'code_is 1 && has "member \`passwd\` is not a regular file or directory; refusing to extract it"'
  app "$W/oldapp" '  mb_dep("old", "1.0.0");
' 'import "old/old";
fn main() -> int32 {
  return old_x() - 1;
}'
  cd "$W/oldapp" || exit 1
  mb build
  check "yanked version refused when not locked ($form)" eval 'code_is 1 && has "old 1.0.0 is yanked in registry default"'

  # publish and yank refuse
  cd "$W/app" || exit 1
  mb yank textkit@v1.0.0
  check "yank refused ($form)" eval 'code_is 1 && has "error: registry default is a Mettle registry, published by the Mettle repository'"'"'s website/registry.py"'
  mb publish
  check "publish refused ($form)" eval 'code_is 1 && has "website/registry.py"'
done

echo "== publish --to a Mettle registry directory"
cd "$S/path/app" || exit 1
mb publish --to "$REG"
check "publish --to refused" eval 'code_is 1 && has "is a Mettle registry, published by the Mettle repository'"'"'s website/registry.py"'

echo "== a broken index"
mkdir -p "$S/broken/v1"
printf '{"format": 1, "packages": [' >"$S/broken/v1/index.json"
export MBUILD_HOME="$S/home-broken" MBUILD_REGISTRY="$S/broken"
app "$S/brokenapp" "$DEPS" "$MAIN"
cd "$S/brokenapp" || exit 1
mb build
check "invalid JSON is an error" eval 'code_is 1 && has "v1/index.json is not valid JSON (unexpected end"'
printf '{"format": 2, "packages": []}' >"$S/broken/v1/index.json"
rm -rf "$S/home-broken"
mb build
check "another format is an error" eval 'code_is 1 && has "is not a format 1 index"'

echo "== bare package imports (import \"greet\";)"
mkdir -p "$S/probe/p/greetp" && printf 'export fn gp() -> int32 {\n  return 0;\n}\n' >"$S/probe/p/greetp/greetp.mettle"
printf 'import "greetp";\nfn main() -> int32 {\n  return gp();\n}\n' >"$S/probe/main.mettle"
printf 'greetp=p/greetp\n' >"$S/probe/mettle.deps"
if (cd "$S/probe" && "$METTLE" --build main.mettle -o m >/dev/null 2>&1); then
  export MBUILD_HOME="$S/home-path" MBUILD_REGISTRY="$REG"
  app "$S/bare" "$DEPS" 'import "std/io";
import "greet";
import "textkit";

fn main() -> int32 {
  println(gr_hello(tk_version()));
  return 0;
}'
  cd "$S/bare" || exit 1
  mb run
  check "bare imports load the package's main module" eval 'code_is 0 && has "hello textkit 1.1.0!"'
else
  echo "note: bare package imports skipped (the compiler predates them)"
fi
cd "$S" || exit 1

echo "$pass passed, $failed failed"
[ $failed = 0 ]
