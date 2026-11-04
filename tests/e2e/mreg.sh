#!/bin/sh
# mreg.sh: a registry in the Mettle project's format through a path and
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
count_is() { [ "$(grep -cF -- "$1" "$S/last.out")" = "$2" ]; }
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

echo "== mbuild search"
"$METTLE" --build --release "$here/src/main.mettle" -o "$S/mbuild-release" >"$S/build-release.log" 2>&1 || { cat "$S/build-release.log"; exit 1; }
search_suite() { # MODE
  mode="$1"
  if [ $mode = debug ]; then MB="$S/mbuild"; else MB="$S/mbuild-release"; fi
  export MBUILD_HOME="$S/home-search-$mode" MBUILD_REGISTRY="$REG"
  W="$S/search-$mode"
  rm -rf "$W" "$MBUILD_HOME"; mkdir -p "$W/plain"
  cd "$W/plain" || exit 1
  mb search
  check "search lists every package, outside a project ($mode)" eval 'code_is 0 && has "greet 1.0.0  the \"greet\" package" && has "  fns: gr_hello" && has "textkit 1.1.0  " && has "  fns: tk_twice, tk_shout, tk_version"'
  check "search sorts by name, a blank line between blocks ($mode)" sh -c '[ "$(grep -v "^ \|^$\|Created" "$0" | cut -d" " -f1 | tr "\n" " ")" = "badsha evil greet textkit " ] && [ "$(grep -c "^$" "$0")" = 3 ]' "$S/last.out"
  check "search skips a package with only yanked versions ($mode)" hasnt "old 1.0.0"
  check "search says why a package has no functions ($mode)" eval 'has "badsha 1.0.0" && has "fns: unknown (badsha v1.0.0 from registry default does not match its index)" && has "fns: unknown (evil-1.0.0.tar: member \`passwd\` is not a regular file"'
  check "search leaves no unpacked archive ($mode)" sh -c '[ ! -e "$MBUILD_HOME/search" ]'
  mb search greet
  check "search by name ($mode)" eval 'code_is 0 && has "greet 1.0.0" && hasnt "textkit"'
  mb search GREET
  check "search ignores case ($mode)" eval 'code_is 0 && has "greet 1.0.0" && hasnt "textkit"'
  mb search '"textkit" package'
  check "search by description ($mode)" eval 'code_is 0 && has "textkit 1.1.0" && hasnt "greet"'
  mb search tk_shout
  check "search by function name ($mode)" eval 'code_is 0 && has "textkit 1.1.0" && hasnt "greet"'
  mb search GR_HEL
  check "search by part of a function name, any case ($mode)" eval 'code_is 0 && has "greet 1.0.0" && has "  fns: gr_hello" && hasnt "textkit"'
  mb search zzz
  check "search with no match exits 1 ($mode)" eval 'code_is 1 && [ "$(cat "$S/last.out")" = "error: no package matches zzz" ]'
  mb search -q
  check "search -q prints names only ($mode)" eval 'code_is 0 && grep -v Created "$S/last.out" | grep -qx "badsha" && [ "$(grep -v Created "$S/last.out" | tr "\n" " ")" = "badsha evil greet textkit " ]'
  mb search -q tk_
  check "search -q matches functions too ($mode)" eval 'code_is 0 && [ "$(cat "$S/last.out")" = "textkit" ]'
  mb search a b
  check "search takes one TEXT ($mode)" eval 'code_is 1 && has "mbuild search takes one TEXT"'

  echo "== mbuild search --offline ($mode)"
  MBUILD_HOME="$W/cold" mb --offline search
  check "offline with no cached index ($mode)" eval 'code_is 1 && has "the index of registry default is not in the download cache and --offline forbids fetching it" && has "help: run mbuild search once while online"'
  mb search textkit
  cp "$S/last.out" "$W/online.out"
  mb --offline search textkit
  check "offline from the cache gives the same answer ($mode)" cmp -s "$S/last.out" "$W/online.out"
  mb --offline search
  check "offline lists the packages whose archive is gone ($mode)" eval 'code_is 0 && has "fns: unknown (badsha v1.0.0 is not in the download cache and --offline forbids fetching it)" && has "  fns: tk_twice, tk_shout, tk_version"'
  rm -f "$MBUILD_HOME"/registry/default@*/v1/archives/greet-1.0.0.tar
  mb --offline search greet
  check "offline with an uncached archive says so ($mode)" eval 'code_is 0 && has "greet 1.0.0" && has "fns: unknown (greet v1.0.0 is not in the download cache and --offline forbids fetching it)"'
  mb --offline search -q greet
  check "offline -q needs no archive ($mode)" eval 'code_is 0 && [ "$(cat "$S/last.out")" = "greet" ]'

  echo "== mbuild search, two registries ($mode)"
  rm -rf "$W/copy" "$W/two"; cp -r "$REG" "$W/copy"
  rm -rf "$W/copy/v1/archives/evil-1.0.0.tar" "$W/copy/v1/archives/badsha-1.0.0.tar"
  mkdir -p "$W/two"
  printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("two", "0.1.0");\n  mb_registry("copy", "%s");\n}\n' "$W/copy" >"$W/two/mbuild.mettle"
  cd "$W/two" || exit 1
  mb search greet
  check "search asks every registry, the same name is tagged ($mode)" eval 'code_is 0 && has "greet 1.0.0 (registry copy)  " && has "greet 1.0.0 (registry default)  "'
  check "the project's registries come first ($mode)" sh -c '[ "$(grep -c "^greet" "$0")" = 2 ] && [ "$(grep "^greet" "$0" | head -1 | grep -c copy)" = 1 ]' "$S/last.out"
  mb search -q greet
  check "search -q names a package once ($mode)" eval 'code_is 0 && [ "$(cat "$S/last.out")" = "greet" ]'
  printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("two", "0.1.0");\n  mb_registry("gone", "%s");\n}\n' "$W/nowhere" >"$W/two/mbuild.mettle"
  mb search textkit
  check "a registry that fails is an error, the others still answer ($mode)" eval 'code_is 1 && has "error: registry gone" && has "textkit 1.1.0"'
  cd "$S" || exit 1
}
search_suite debug
search_suite release
if [ -n "$H" ]; then
  MB="$S/mbuild"
  export MBUILD_HOME="$S/home-search-http" MBUILD_REGISTRY="$H"
  rm -rf "$MBUILD_HOME"; mkdir -p "$S/search-http"; cd "$S/search-http" || exit 1
  mb search tk_twice
  check "search through http" eval 'code_is 0 && has "textkit 1.1.0" && has "  fns: tk_twice, tk_shout, tk_version"'
  cd "$S" || exit 1
fi
MB="$S/mbuild"

echo "== mbuild info"
info_suite() { # MODE
  mode="$1"
  if [ $mode = debug ]; then MB="$S/mbuild"; else MB="$S/mbuild-release"; fi
  export MBUILD_HOME="$S/home-info-$mode" MBUILD_REGISTRY="$REG"
  W="$S/info-$mode"
  rm -rf "$W" "$MBUILD_HOME"; mkdir -p "$W/plain"
  cd "$W/plain" || exit 1
  mb info textkit
  check "info: the newest version first ($mode)" eval 'code_is 0 && grep -qx "textkit 1.1.0" "$S/last.out"'
  check "info: the details ($mode)" eval 'has "  textkit test package" && has "  License:       MIT" && has "  Source:        https://example.com/textkit" && has "  Registry:      default" && has "  Versions:      1.1.0, 1.0.0" && hasnt "Dependencies" && hasnt "Docs:"'
  check "info: the README intro, up to the first heading ($mode)" eval 'has "  Small text helpers: shout, twice." && has "  No allocation." && hasnt "## Use" && hasnt "import \"textkit"'
  check "info: functions by file, doc comments above them ($mode)" sh -c '[ "$(sed -n "/^    textkit.mettle/,\$p" "$0/last.out")" = "$(printf "    textkit.mettle\n      // Appends a bang to s.\n      // Keeps the case.\n      fn tk_shout(s: string) -> string\n\n      /// The version of this textkit.\n      fn tk_version() -> string")" ]' "$S"
  check "info: a comment a blank line away is no doc ($mode)" eval 'has "    extra.mettle" && has "      fn tk_twice(s: string) -> string" && hasnt "blank line away"'
  check "info: leaves no unpacked archive ($mode)" sh -c '[ ! -e "$MBUILD_HOME/search" ]'
  mb info textkit@1.0.0
  check "info PKG@VERSION ($mode)" eval 'has "textkit 1.0.0" && hasnt "textkit 1.1.0" && has "  Versions:      1.1.0, 1.0.0" && hasnt "Small text helpers"'
  mb info textkit@v1.0.0
  check "info PKG@vVERSION ($mode)" has "textkit 1.0.0"
  mb info textkit@1
  check "info PKG@LINE is the newest in the line ($mode)" has "textkit 1.1.0"
  mb info textkit@9
  check "info of a version that is not there ($mode)" eval 'code_is 1 && has "error: textkit has no version 9" && has "help: available versions: 1.0.0, 1.1.0"'
  mb info greet
  check "info: dependencies of the version ($mode)" eval 'code_is 0 && has "  Dependencies:  textkit 1.0.0" && has "      fn gr_hello(name: string) -> string"'
  mb info old
  check "info: a yanked version is marked ($mode)" eval 'code_is 0 && has "old 1.0.0 (yanked)" && has "  Versions:      1.0.0 (yanked)"'
  mb info gret
  check "info of an unknown name: did you mean ($mode)" eval 'code_is 1 && has "error: no registry has a package named gret (searched default)" && has "help: did you mean greet? (in registry default)"'
  mb info nosuch
  check "info of an unknown name ($mode)" eval 'code_is 1 && has "error: no registry has a package named nosuch (searched default)" && hasnt "did you mean"'
  mb info badsha
  check "info refuses an archive that does not match its index ($mode)" eval 'code_is 1 && has "badsha v1.0.0 from registry default does not match its index"'
  mb info
  check "info takes a package ($mode)" eval 'code_is 1 && has "mbuild info takes one PKG[@VERSION]"'
  mb info textkit --readme
  check "info --readme prints the README as is ($mode)" cmp -s "$S/last.out" "$S/fx/msrc/textkit-1.1.0/README.md"
  mb info greet --readme
  check "info --readme of a package with none lists its functions ($mode)" eval 'code_is 0 && has "greet has no README; its exported functions:" && has "      fn gr_hello(name: string) -> string"'
  mb info greet
  check "info of a package with no README still lists its functions ($mode)" eval 'code_is 0 && has "    greet.mettle" && hasnt "README"'

  echo "== mbuild info --offline ($mode)"
  MBUILD_HOME="$W/cold" mb --offline info textkit
  check "offline with nothing cached ($mode)" eval 'code_is 1 && has "--offline forbids fetching it"'
  mb info textkit
  cp "$S/last.out" "$W/online.out"
  mb --offline info textkit
  check "offline from the cache gives the same answer ($mode)" cmp -s "$S/last.out" "$W/online.out"
  rm -f "$MBUILD_HOME"/registry/default@*/v1/archives/greet-1.0.0.tar
  mb --offline info greet
  check "offline with an uncached archive says so ($mode)" eval 'code_is 1 && has "--offline forbids fetching it"'

  echo "== mbuild __complete packages ($mode)"
  mb __complete packages
  check "__complete packages lists the cached index, in index order ($mode)" sh -c '[ "$(tr "\n" " " <"$0/last.out")" = "textkit greet badsha evil old " ]' "$S"
  mb __complete packages g
  check "__complete packages takes a prefix ($mode)" sh -c '[ "$(cat "$0/last.out")" = greet ]' "$S"
  MBUILD_HOME="$W/cold2" MBUILD_REGISTRY="http://127.0.0.1:9/" mb __complete packages
  check "__complete packages never goes to the network ($mode)" eval 'code_is 0 && [ ! -s "$S/last.out" ]'

  echo "== search, info and __complete packages with no compiler ($mode)"
  mkdir -p "$W/proj"
  printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("proj", "0.1.0");\n}\n' >"$W/proj/mbuild.mettle"
  cd "$W/proj" || exit 1
  if command -v mettle >/dev/null 2>&1; then
    echo "note: no-compiler tests skipped (mettle is on PATH)"
  else
    nocc() { env -u METTLE -u MBUILD_METTLE_LINUX "$MB" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }
    nocc build
    check "the project cannot be built with no compiler ($mode)" eval 'code_is 1 && has "error: no Mettle compiler for linux"'
    nocc search tk_
    check "search with no compiler: one note, the registries that need no evaluation ($mode)" eval 'code_is 0 && has "note: no Mettle compiler to read mbuild.mettle with: its registries are skipped" && count_is "note:" 1 && has "textkit 1.1.0" && hasnt "no Mettle compiler for"'
    nocc info textkit
    check "info with no compiler ($mode)" eval 'code_is 0 && has "note: no Mettle compiler to read mbuild.mettle with: its registries are skipped" && grep -qx "textkit 1.1.0" "$S/last.out"'
    nocc __complete packages
    check "__complete packages with no compiler: quiet ($mode)" eval 'code_is 0 && has "textkit" && hasnt "note" && hasnt "error"'
    nocc info .
    check "info . needs the compiler ($mode)" eval 'code_is 1 && has "error: no Mettle compiler for linux" && hasnt "registries are skipped"'
  fi
  cd "$S" || exit 1
}
info_suite debug
info_suite release
if [ -n "$H" ]; then
  MB="$S/mbuild"
  export MBUILD_HOME="$S/home-info-http" MBUILD_REGISTRY="$H"
  rm -rf "$MBUILD_HOME"; mkdir -p "$S/info-http"; cd "$S/info-http" || exit 1
  mb info textkit
  check "info through http: the registry's page for the package" eval 'code_is 0 && has "  Docs:          ${H}textkit/"'
  cd "$S" || exit 1
fi
MB="$S/mbuild"

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
