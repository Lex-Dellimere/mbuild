#!/bin/sh
# registry.sh: sha256 and the file registry (tests/unit/registry_test.mettle; METTLE_WIN: also under wine).
#   METTLE=dev-compiler sh tests/e2e/registry.sh   (scratch: $MBTEST_TMP)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
S="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-user}/registry}"
rm -rf "$S"
mkdir -p "$S"
export WINEDEBUG=-all
export LC_ALL=C
unset MBUILD_REGISTRY_CORP MBUILD_CURL MBUILD_TAR

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -40; }
check() { # name, command...
  name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name" "$(cat "$S/last.out" 2>/dev/null)"; fi
}
has() { grep -qF -- "$1" "$S/last.out"; }
hasnt() { ! grep -qF -- "$1" "$S/last.out"; }
code_is() { [ "$(cat "$S/last.code")" = "$1" ]; }
count_is() { [ "$(grep -cF -- "$1" "$S/last.out")" = "$2" ]; }
# run ARGS...: the driver with stdout+stderr in last.out, exit code in last.code
run() { "$DRV" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }
sum() { sha256sum | cut -c1-64; }
# mbs ARGS...: mbuild (MBS) in the empty directory SW, outside any project (tar's note on the ../ fixture dropped)
mbs() { ( cd "$SW" && "$MBS" "$@" ) >"$S/last.out" 2>&1; echo $? >"$S/last.code"; sed -i '/Removing leading/d' "$S/last.out"; }

echo "== building the driver"
for mode in debug release; do
  flag=""; [ $mode = release ] && flag="--release"
  "$METTLE" --build $flag "$here/tests/unit/registry_test.mettle" -o "$S/drv-$mode" >"$S/build-$mode.log" 2>&1 || { cat "$S/build-$mode.log"; exit 1; }
  if grep -q 'warning' "$S/build-$mode.log"; then bad "driver builds without warnings ($mode)" "$(cat "$S/build-$mode.log")"; fi
  "$METTLE" --build $flag "$here/src/main.mettle" -o "$S/mbuild-$mode" >"$S/build-mbuild-$mode.log" 2>&1 || { cat "$S/build-mbuild-$mode.log"; exit 1; }
done

echo "== fixtures"
F="$S/fx"
sh "$here/tests/fixtures/make-registry.sh" "$F" >/dev/null 2>&1 || { echo "make-registry.sh failed"; exit 1; }
REG="$F/registry"
sh "$here/tests/fixtures/make-mettle-registry.sh" "$S/fxm" >/dev/null || { echo "make-mettle-registry.sh failed"; exit 1; }
head -c 16777216 /dev/urandom >"$S/big.bin"
pids=""
trap 'kill $pids 2>/dev/null' EXIT
# serve DIR: an http server on a free port for DIR; sets port and pid
serve() {
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  (cd "$1" && exec python3 -m http.server "$port" --bind 127.0.0.1 >>"$S/http.log" 2>&1) &
  pid=$!
  pids="$pids $pid"
  i=0
  while [ $i -lt 50 ] && ! curl -fs "http://127.0.0.1:$port/registry.toml" >/dev/null 2>&1; do sleep 0.1; i=$((i + 1)); done
}
port=""
if command -v python3 >/dev/null 2>&1; then
  serve "$REG"
fi

suite() { # MODE
  mode="$1"
  DRV="$S/drv-$mode"
  T="$S/$mode"
  mkdir -p "$T/app"
  export MBUILD_HOME="$T/home"
  export MBUILD_REGISTRY="$REG"
  echo "== sha256 ($mode)"
  run sha-string ""; check "sha \"\" ($mode)" [ "$(cat "$S/last.out")" = "$(printf '' | sum)" ]
  run sha-string abc; check "sha abc ($mode)" [ "$(cat "$S/last.out")" = "$(printf abc | sum)" ]
  for n in 55 56 64 1000000; do
    run sha-repeat a $n
    check "sha of $n bytes ($mode)" [ "$(cat "$S/last.out")" = "$(head -c $n /dev/zero | tr '\0' a | sum)" ]
  done
  run sha-file "$S/big.bin"; check "sha_file 16 MB ($mode)" [ "$(cat "$S/last.out")" = "$(sum <"$S/big.bin")" ]
  run sha-file "$S/absent"; check "sha_file of a missing file is empty ($mode)" [ "$(cat "$S/last.out")" = "<none>" ]

  echo "== registry list ($mode)"
  run list "$T/app"; check "default from MBUILD_REGISTRY ($mode)" [ "$(cat "$S/last.out")" = "default $REG" ]
  mkdir -p "$T/corpapp"
  printf '[package]\nname = "corpapp"\n\n[registry.corp]\nurl = "../corp"\n' >"$T/corpapp/manifest.toml"
  run list "$T/corpapp"; check "declared registries come first ($mode)" [ "$(cat "$S/last.out")" = "$(printf 'corp ../corp\ndefault %s' "$REG")" ]
  run dir "$T/corpapp" corp; check "a relative path registry is against the root ($mode)" [ "$(cat "$S/last.out")" = "$T/corp" ]
  printf '[registry.corp]\nurl = "/local/corp"\n' >"$T/corpapp/local.toml"
  run list "$T/corpapp"; check "mbuild.local.mettle overrides mbuild.mettle ($mode)" has "corp /local/corp"
  MBUILD_REGISTRY_CORP="file:///env/corp" run list "$T/corpapp"; check "MBUILD_REGISTRY_CORP overrides both ($mode)" has "corp file:///env/corp"
  MBUILD_REGISTRY_CORP="file:///env/corp" run dir "$T/corpapp" corp; check "reg_dir_of file:// ($mode)" [ "$(cat "$S/last.out")" = "/env/corp" ]
  MBUILD_REGISTRY_CORP="https://x.invalid/r" run dir "$T/corpapp" corp; check "reg_dir_of https is empty ($mode)" [ "$(cat "$S/last.out")" = "<none>" ]
  rm "$T/corpapp/local.toml"
  MBUILD_REGISTRY= run list "$T/app"
  check "the default registry is the Mettle one ($mode)" [ "$(cat "$S/last.out")" = "default https://the-mettle-project.github.io/Mettle/registry/" ]

  echo "== index ($mode)"
  run index "$T/app" default strutil
  check "path registry index ($mode)" eval 'code_is 0 && has "found=1 n=3" && grep -qx "v1.1.0 $(grep "^v1.1.0 " "$REG/index/strutil" | sed "s/.*sha256=\([0-9a-f]*\) manifest=\([0-9a-f]*\).*/\1 \2/")" "$S/last.out"'
  sed 1d "$S/last.out" >"$S/idx-path"
  MBUILD_REGISTRY="file://$REG" run index "$T/app" default strutil
  sed 1d "$S/last.out" >"$S/idx-file"
  check "file:// index equals the path one ($mode)" cmp -s "$S/idx-path" "$S/idx-file"
  run index "$T/app" default nope; check "missing package, path ($mode)" eval 'code_is 0 && has "ok=1 found=0" && has "kind missing"'
  MBUILD_REGISTRY="file://$REG" run index "$T/app" default nope; check "missing package, file:// ($mode)" eval 'has "ok=1 found=0" && has "kind missing"'
  run index "$T/app" default yanky; check "yanked flag ($mode)" eval 'has "v1.0.1 " && has " yanked"'
  if [ -n "$port" ]; then
    H="http://127.0.0.1:$port"
    MBUILD_REGISTRY="$H" run index "$T/app" default strutil
    grep -v '^warning' "$S/last.out" | sed 1d >"$S/idx-http"
    check "http index equals the path one ($mode)" cmp -s "$S/idx-path" "$S/idx-http"
    check "http warns once ($mode)" count_is "uses http://" 1
    MBUILD_REGISTRY="$H" run index "$T/app" default nope
    check "missing package, http: curl exit 22 ($mode)" eval 'has "ok=1 found=0" && has "kind missing" && has "404"'
  else
    echo "note: python3 not found; http registry tests skipped"
  fi
  export MBUILD_HOME="$T/home-v"
  run index "$T/app" default strutil -v --twice; check "refresh=false twice fetches once ($mode)" count_is "Updating index of strutil" 1
  run index "$T/app" default strutil -v --twice --refresh; check "refresh=true twice fetches once per command ($mode)" count_is "Updating index of strutil" 1
  run index "$T/app" default strutil -v; check "a cached index is not fetched again ($mode)" count_is "Updating" 0
  export MBUILD_HOME="$T/home"

  echo "== find ($mode)"
  "$DRV" init "$T/corp" corp >/dev/null
  mkdir -p "$T/mine/src"
  printf 'export fn mi() -> int32 {\n  return 1;\n}\n' >"$T/mine/src/mine.mettle"
  printf '[package]\nname = "mine"\nversion = "v0.1.0"\n' >"$T/mine/manifest.toml"
  "$DRV" publish "$T/corp" mine v0.1.0 "$T/mine/src" "$T/mine/manifest.toml" >/dev/null
  run find "$T/corpapp" strutil; check "find falls through to default ($mode)" has "registry=default ok=1 found=1"
  run find "$T/corpapp" mine; check "find takes the first registry that has it ($mode)" has "registry=corp ok=1 found=1"
  run find "$T/corpapp" strutil corp; check "a pinned registry only ($mode)" has "ok=1 found=0"
  run find "$T/corpapp" nope; check "not found anywhere ($mode)" has "no registry has a package named nope (searched corp, default)"
  MBUILD_REGISTRY_CORP="http://127.0.0.1:1" run find "$T/corpapp" strutil
  check "a network failure stops the search ($mode)" eval 'has "ok=0 found=0" && has "kind network"'

  echo "== manifests ($mode)"
  run manifest "$T/app" default textfmt v0.1.0; check "textfmt depends on strutil v1.1.0 ($mode)" eval 'code_is 0 && has "package textfmt v0.1.0" && has "dep strutil v1.1.0"'
  run manifest "$T/app" default textfmt v9.9.9; check "absent version ($mode)" eval 'code_is 1 && has "has no textfmt v9.9.9"'
  rm -rf "$T/reg2"; cp -r "$REG" "$T/reg2"
  printf '# changed\n' >>"$T/reg2/pkg/textfmt/textfmt-v0.1.0.toml"
  MBUILD_REGISTRY="$T/reg2" run manifest "$T/app" default textfmt v0.1.0
  check "a changed manifest is refused ($mode)" eval 'code_is 1 && has "does not match"'

  echo "== archives ($mode)"
  D="$T/app/.mbuild/deps"
  run get "$T/app" default strutil v1.1.0 "$D/strutil"
  a=$(grep '^v1.1.0 ' "$REG/index/strutil" | sed 's/.*sha256=\([0-9a-f]*\).*/\1/')
  check "fetch + extract strutil v1.1.0 ($mode)" eval 'code_is 0 && [ -f "$D/strutil/strutil.mettle" ] && has "Fetching strutil v1.1.0 (default)"'
  check "marker line ($mode)" has "marker strutil v1.1.0 sha256:$a default"
  check "marker file ($mode)" [ "$(cat "$D/strutil/.mbuild-pkg")" = "strutil v1.1.0 sha256:$a default" ]
  check "the temp directory is gone ($mode)" [ ! -e "$T/app/.mbuild/tmp/x-strutil" ]
  run get "$T/app" default strutil v1.1.0 "$D/strutil"; check "a cached archive is not fetched again ($mode)" eval 'code_is 0 && hasnt "Fetching"'
  run get "$T/app" default evil v1.0.0 "$D/evil"
  check "a symlink member is refused ($mode)" eval 'code_is 1 && has "member \`passwd\`" && [ ! -e "$D/evil" ]'
  run get "$T/app" default dotdot v1.0.0 "$D/dotdot"
  check "a ../ member is refused ($mode)" eval 'code_is 1 && has "member \`../x\`" && [ ! -e "$D/dotdot" ] && [ ! -e "$T/app/.mbuild/x" ]'
  run get "$T/app" default badsum v1.0.0 "$D/badsum"
  check "a wrong archive checksum is the mismatch error ($mode)" eval 'code_is 1 && has "badsum v1.0.0 from registry default does not match its index" && has "sha256:9f8e7d6c5b4a3921..." && has "tampered with"'
  run fetch "$T/app" default strutil v1.0.0
  run extract "$(grep '^archive ' "$S/last.out" | cut -c9-)" "sha256:$a" "$D/x" "x"
  check "reg_extract checks the checksum first ($mode)" eval 'code_is 1 && has "does not match its checksum" && [ ! -e "$D/x" ]'

  echo "== offline ($mode)"
  export MBUILD_HOME="$T/home-off"
  run get "$T/app" default strutil v1.0.0 "$D/s10" --offline
  check "offline with an empty cache ($mode)" eval 'code_is 1 && has "not in the download cache and --offline forbids fetching it"'
  run get "$T/app" default strutil v1.0.0 "$D/s10"; check "online once ($mode)" code_is 0
  run get "$T/app" default strutil v1.0.0 "$D/s10" --offline; check "then offline works ($mode)" eval 'code_is 0 && [ -f "$D/s10/strutil.mettle" ]'
  run fetch "$T/app" default strutil v1.1.0 --offline
  check "offline: an uncached archive of a cached index ($mode)" eval 'code_is 1 && has "strutil v1.1.0 is not in the download cache" && has "help: run mbuild fetch once while online"'
  run index "$T/app" default textfmt --offline; check "offline: an uncached index ($mode)" eval 'has "found=0" && has "--offline forbids"'
  if [ -n "$port" ]; then
    export MBUILD_HOME="$T/home-net"
    keep="$port"
    serve "$REG"
    H2="http://127.0.0.1:$port"
    port="$keep"
    MBUILD_REGISTRY="$H2" run index "$T/app" default strutil
    kill $pid; wait $pid 2>/dev/null
    MBUILD_REGISTRY="$H2" run index "$T/app" default strutil --refresh
    check "unreachable with a cached index: warning, cache used ($mode)" eval 'code_is 0 && has "found=1 n=3" && has "warning: registry default is unreachable (curl: " && has "using the cached index"'
    MBUILD_REGISTRY="$H2" run index "$T/app" default textfmt
    check "unreachable without a cached index ($mode)" eval 'code_is 1 && has "ok=0" && has "kind network"'
  fi
  export MBUILD_HOME="$T/home"

  echo "== publish ($mode)"
  P="$T/pub"
  run init "$P" pub; check "reg_init_dir ($mode)" eval 'code_is 0 && [ -f "$P/registry.toml" ] && [ -d "$P/index" ] && [ -d "$P/pkg" ]'
  run init "$P" pub; check "init twice ($mode)" eval 'code_is 1 && has "already a registry"'
  mkdir -p "$T/pk/src/sub"
  printf 'export fn pk() -> int32 {\n  return 7;\n}\n' >"$T/pk/src/pk.mettle"
  printf 'x\n' >"$T/pk/src/sub/data.txt"
  printf '[package]\nname = "pk"\nversion = "v1.0.0"\n\n[dependencies]\nstrutil = "v1.0.0"\n' >"$T/pk/manifest.toml"
  run publish "$P" pk v1.0.0 "$T/pk/src" "$T/pk/manifest.toml" --dry-run
  check "dry run lists, writes nothing ($mode)" eval 'code_is 0 && has "sub/data.txt" && has "[dependencies]" && [ ! -f "$P/index/pk" ]'
  run publish "$P" pk v1.0.0 "$T/pk/src" "$T/pk/manifest.toml"
  check "publish ($mode)" eval 'code_is 0 && [ -f "$P/pkg/pk/pk-v1.0.0.tar.gz" ] && [ -f "$P/pkg/pk/pk-v1.0.0.toml" ] && head -1 "$P/index/pk" | grep -qx "# mbuild index pk"'
  check "index line checksums equal sha256sum ($mode)" grep -qx "v1.0.0 sha256=$(sum <"$P/pkg/pk/pk-v1.0.0.tar.gz") manifest=$(sum <"$P/pkg/pk/pk-v1.0.0.toml")" "$P/index/pk"
  check "archive members are relative to the package root ($mode)" [ "$(tar -tzf "$P/pkg/pk/pk-v1.0.0.tar.gz" | tr '\n' ' ')" = "pk.mettle sub/data.txt " ]
  export MBUILD_REGISTRY="$P"
  run get "$T/app" default pk v1.0.0 "$T/app/.mbuild/deps/pk"
  check "read back ($mode)" eval 'code_is 0 && [ -f "$T/app/.mbuild/deps/pk/sub/data.txt" ] && has "marker pk v1.0.0 sha256:"'
  run manifest "$T/app" default pk v1.0.0; check "published manifest ($mode)" has "dep strutil v1.0.0"
  run publish "$P" pk v1.0.0 "$T/pk/src" "$T/pk/manifest.toml"; check "the same version twice ($mode)" eval 'code_is 1 && has "already published"'
  run publish "$T/nowhere" pk v1.0.0 "$T/pk/src" "$T/pk/manifest.toml"; check "publish into a non-registry ($mode)" eval 'code_is 1 && has "not a registry"'
  sed -i 's/v1.0.0/v1.0.1/' "$T/pk/manifest.toml"
  run publish "$P" pk v1.0.1 "$T/pk/src" "$T/pk/manifest.toml"; check "a second version ($mode)" eval 'code_is 0 && [ "$(grep -c "^v" "$P/index/pk")" = 2 ]'
  run yank "$P" pk v1.0.0
  run index "$T/app" default pk --refresh; check "yank ($mode)" eval 'grep -q "^v1.0.0 .* yanked$" "$S/last.out" && ! grep -q "^v1.0.1 .*yanked" "$S/last.out"'
  run yank "$P" pk v1.0.0 --undo
  run index "$T/app" default pk --refresh; check "yank --undo ($mode)" hasnt "yanked"
  run yank "$P" pk v3.0.0; check "yank of an absent version ($mode)" eval 'code_is 1 && has "has no pk v3.0.0"'
  export MBUILD_REGISTRY="$REG"

  echo "== search ($mode)"
  MBS="$S/mbuild-$mode"
  SW="$T/search-cwd"
  mkdir -p "$SW"
  export MBUILD_HOME="$T/home-search" NO_COLOR=1
  names_of() { grep -E '^[a-z0-9]+ v[0-9]' "$S/last.out" | cut -d' ' -f1; }
  mbs search
  check "search lists every package ($mode)" eval 'code_is 0 && has "textfmt v0.1.0  text formatting" && has "  fns: tf_banner" && has "strutil v2.0.0-rc.1" && has "  fns: su_shout, su_version, su_twice"'
  check "search sorts by name ($mode)" eval '[ "$(names_of | tr "\n" " ")" = "$(names_of | LC_ALL=C sort | tr "\n" " ")" ] && [ "$(names_of | wc -l)" -gt 10 ]'
  check "search shows the newest version that is not yanked ($mode)" eval 'has "yanky v1.0.0" && hasnt "yanky v1.0.1"'
  check "search leaves no unpacked archive ($mode)" sh -c '[ ! -e "$MBUILD_HOME/search" ]'
  mbs search vecm
  check "search by name ($mode)" eval 'code_is 0 && has "vecmath v0.3.0" && has "  fns: vm_banner, vm_one" && hasnt "strutil"'
  mbs search FORMATTING
  check "search by description, any case ($mode)" eval 'code_is 0 && has "textfmt v0.1.0  text formatting" && hasnt "strutil"'
  mbs search su_twice
  check "search by function name ($mode)" eval 'code_is 0 && has "strutil v2.0.0-rc.1" && hasnt "textfmt"'
  mbs search TF_BAN
  check "search by part of a function name, any case ($mode)" eval 'code_is 0 && has "textfmt v0.1.0" && hasnt "strutil"'
  mbs search zzz
  check "search with no match exits 1 ($mode)" eval 'code_is 1 && [ "$(cat "$S/last.out")" = "error: no package matches zzz" ]'
  mbs search -q vecm
  check "search -q prints names only ($mode)" eval 'code_is 0 && [ "$(cat "$S/last.out")" = "vecmath" ]'
  mbs search -q
  check "search -q lists every name ($mode)" eval 'code_is 0 && has "strutil" && hasnt " v" && hasnt "fns"'
  mbs search dotdot
  check "search says why a package has no functions ($mode)" eval 'code_is 0 && has "dotdot v1.0.0" && has "fns: unknown (dotdot-v1.0.0.tar.gz: member \`../x\` leaves the package directory"'

  echo "== search --offline ($mode)"
  MBUILD_HOME="$T/home-search-cold" mbs --offline search
  check "offline with no cached index ($mode)" eval 'code_is 1 && has "the index of registry default is not in the download cache and --offline forbids fetching it" && has "help: run mbuild search once while online"'
  mbs search textfmt
  cp "$S/last.out" "$T/search-online.out"
  mbs --offline search textfmt
  check "offline from the cache gives the same answer ($mode)" cmp -s "$S/last.out" "$T/search-online.out"
  rm -f "$MBUILD_HOME"/registry/default@*/pkg/textfmt/textfmt-v0.1.0.tar.gz
  mbs --offline search textfmt
  check "offline with an uncached archive says so ($mode)" eval 'code_is 0 && has "textfmt v0.1.0  text formatting" && has "fns: unknown (textfmt v0.1.0 is not in the download cache and --offline forbids fetching it)"'
  mbs --offline search -q textfmt
  check "offline -q needs no archive ($mode)" eval 'code_is 0 && [ "$(cat "$S/last.out")" = "textfmt" ]'

  echo "== info ($mode)"
  mbs info textfmt
  check "info: description, registry, dependencies, functions ($mode)" eval 'code_is 0 && grep -qx "textfmt v0.1.0" "$S/last.out" && has "  text formatting" && has "  Registry:      default" && has "  Dependencies:  strutil v1.1.0" && has "    textfmt.mettle" && has "      fn tf_banner(s: string) -> string" && hasnt "Docs:"'
  check "info leaves no unpacked archive ($mode)" sh -c '[ ! -e "$MBUILD_HOME/search" ]'
  mbs info strutil
  check "info takes the newest stable version ($mode)" eval 'grep -qx "strutil v1.1.0" "$S/last.out" && has "  Versions:      v2.0.0-rc.1, v1.1.0, v1.0.0"'
  mbs info strutil@v2.0.0-rc.1
  check "info PKG@VERSION, a pre-release too ($mode)" eval 'grep -qx "strutil v2.0.0-rc.1" "$S/last.out"'
  mbs info strutil@v1
  check "info PKG@v1 is the newest in the line ($mode)" eval 'grep -qx "strutil v1.1.0" "$S/last.out"'
  mbs info yanky
  check "info: yanked versions are marked ($mode)" eval 'grep -qx "yanky v1.0.0" "$S/last.out" && has "  Versions:      v1.0.1 (yanked), v1.0.0"'
  mbs info yanky@v1.0.1
  check "info of a yanked version ($mode)" eval 'grep -qx "yanky v1.0.1 (yanked)" "$S/last.out"'
  mbs info strutl
  check "info of a misspelled name ($mode)" eval 'code_is 1 && has "error: no registry has a package named strutl (searched default)" && has "help: did you mean strutil? (in registry default)"'
  mbs info strutil@v7
  check "info of a version that is not there ($mode)" eval 'code_is 1 && has "error: strutil has no version v7" && has "help: available versions: v1.0.0, v1.1.0, v2.0.0-rc.1"'
  mbs info strutil --readme
  check "info --readme of a package with none lists its functions ($mode)" eval 'code_is 0 && has "strutil has no README; its exported functions:" && has "      fn su_shout(s: string) -> string"'
  mbs --offline info textfmt
  check "offline from the cache ($mode)" eval 'code_is 0 && grep -qx "textfmt v0.1.0" "$S/last.out"'
  MBUILD_HOME="$T/home-info-cold" mbs --offline info textfmt
  check "offline with nothing cached ($mode)" eval 'code_is 1 && has "--offline forbids fetching it"'
  mbs __complete packages
  check "__complete packages: the cached indexes ($mode)" eval 'code_is 0 && has "strutil" && has "textfmt" && hasnt " "'
  mbs __complete packages text
  check "__complete packages with a prefix ($mode)" eval 'code_is 0 && [ "$(cat "$S/last.out")" = textfmt ]'

  echo "== search, two registries ($mode)"
  rm -rf "$T/regcopy" "$T/two"; cp -r "$REG" "$T/regcopy"
  mkdir -p "$T/two"
  printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("two", "0.1.0");\n  mb_registry("copy", "%s");\n  mb_registry("mettle", "%s");\n}\n' "$T/regcopy" "$S/fxm/mreg" >"$T/two/mbuild.mettle"
  SW="$T/two"
  mbs search -q
  check "search -q names each package once ($mode)" eval 'code_is 0 && count_is strutil 1 && has "greet" && has "textkit" && has "vecmath"'
  mbs search strutil
  check "search asks every registry, the same name is tagged ($mode)" eval 'code_is 0 && has "strutil v2.0.0-rc.1 (registry copy)" && has "strutil v2.0.0-rc.1 (registry default)"'
  mbs search textkit
  check "search reads both registry kinds ($mode)" eval 'code_is 0 && has "textkit 1.1.0  " && has "  fns: tk_twice, tk_shout, tk_version" && hasnt "registry"'
  SW="$T/search-cwd"
  if [ -n "$port" ]; then
    export MBUILD_HOME="$T/home-search-http"
    MBUILD_REGISTRY="http://127.0.0.1:$port" mbs search
    check "an http mbuild registry has no package list ($mode)" eval 'code_is 1 && has "registry default has no list of its packages"'
    MBUILD_REGISTRY="http://127.0.0.1:$port" run index "$T/app" default strutil
    MBUILD_REGISTRY="http://127.0.0.1:$port" mbs search
    check "...so only the cached ones are searched ($mode)" eval 'code_is 0 && has "strutil v2.0.0-rc.1" && has "su_twice" && hasnt "textfmt"'
  fi
  export MBUILD_HOME="$T/home"
}

suite debug
suite release

if [ -n "${METTLE_WIN:-}" ]; then
  echo "== wine"
  "$METTLE_WIN" --build "$here/tests/unit/registry_test.mettle" -o "$S/drv.exe" >"$S/build-win.log" 2>&1 || bad "Windows driver builds" "$(cat "$S/build-win.log")"
  DRV="wine"
  W="$S/wine"; mkdir -p "$W/app"
  export MBUILD_HOME="$W/home" MBUILD_REGISTRY="$REG" MBUILD_UNIX_PATH="/usr/local/bin:/usr/bin:/bin"
  run "$S/drv.exe" sha-string abc; check "wine: sha abc" has "$(printf abc | sum)"
  run "$S/drv.exe" index "Z:$W/app" default strutil; check "wine: path registry index" has "found=1 n=3"
  MBUILD_REGISTRY="file://$REG" run "$S/drv.exe" index "Z:$W/app" default strutil; check "wine: file:// registry index" has "found=1 n=3"
  run "$S/drv.exe" get "Z:$W/app" default strutil v1.1.0 "Z:$W/app/.mbuild/deps/strutil"
  check "wine: fetch + extract" eval '[ -f "$W/app/.mbuild/deps/strutil/strutil.mettle" ]'
  run "$S/drv.exe" get "Z:$W/app" default evil v1.0.0 "Z:$W/app/.mbuild/deps/evil"; check "wine: evil refused" has "passwd"
else
  echo "note: METTLE_WIN not set; wine tests skipped"
fi

echo
echo "registry: $pass passed, $failed failed"
[ $failed -eq 0 ]
