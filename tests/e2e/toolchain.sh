#!/bin/sh
# toolchain.sh: compiler selection, flag probing, minimum versions (tests/unit/toolchain_test.mettle), `mbuild toolchain` and `mbuild setup`.
#   METTLE=dev-compiler sh tests/e2e/toolchain.sh   (scratch: $MBTEST_TMP; METTLE_WIN: also under wine, SKIP_WINE=1 skips it)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
DEV="$(realpath "${METTLE:-$here/../Mettle/bin/mettle}")"
DEVDIR="$(dirname "$(dirname "$DEV")")"
W="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/toolchain}"
rm -rf "$W"
mkdir -p "$W/noproj"
export WINEDEBUG=-all TMPDIR="$W"
export PATH=/usr/local/bin:/usr/bin:/bin
[ "${SKIP_WINE:-0}" = 1 ] && unset METTLE_WIN
METTLE_WIN="${METTLE_WIN:-}"
unset METTLE MBUILD_METTLE_LINUX MBUILD_METTLE_WINDOWS MBUILD_WINE MBUILD_METTLE_API MBUILD_HOME MBUILD_CURL

pass=0
failn=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /'; }
expect() {
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (wanted: $3)" "$2"; fi
}
expect_not() {
  if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (unwanted: $3)" "$2"; else ok "$1"; fi
}
expect_rc() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (exit $2, wanted $3)"; fi
}

if out=$(METTLE="$DEV" sh "$here/tools/mcheck.sh" "$here/tests/unit/toolchain_test.mettle" 2>&1); then ok "driver builds debug and --release without warnings"; else echo "$out"; exit 1; fi
D="$W/mbuild-mcheck/toolchain_test.debug"
DW="$W/mbuild-mcheck/toolchain_test.exe"

# Distinct copies of the dev compiler for each way of naming one.
for k in onpath env flag var local; do
  mkdir -p "$W/fake-$k/bin"
  cp "$DEV" "$W/fake-$k/bin/mettle"
  ln -s "$DEVDIR/stdlib" "$W/fake-$k/stdlib"
done
touch "$W/fake.exe"

echo "== selection (linux)"
export MBUILD_HOME="$W/home"
cd "$W/noproj" || exit 1
o=$("$D" select linux 2>&1); rc=$?
expect_rc "no compiler fails" $rc 1
expect "no compiler: message" "$o" "error: no Mettle compiler for linux"
expect "no compiler: help" "$o" "help: run \`mbuild toolchain install latest\`, or \`mbuild toolchain install --from DIR\` for a Mettle checkout, or set METTLE"
o=$(PATH="$W/fake-onpath/bin:$PATH" "$D" select linux 2>&1)
expect "PATH" "$o" "path=$W/fake-onpath/bin/mettle"
expect "PATH: source" "$o" "source=mettle on PATH"
expect "PATH: stdlib beside the compiler" "$o" "stdlib=$W/fake-onpath/stdlib"
expect "PATH: stdlib readable" "$o" "stdlib_ok=true"
o=$(PATH="$W/fake-onpath/bin:$PATH" METTLE="$W/fake-var/bin/mettle" "$D" select linux 2>&1)
expect "\$METTLE beats PATH" "$o" "path=$W/fake-var/bin/mettle"
expect "\$METTLE source" "$o" 'source=$METTLE'
o=$(METTLE="$W/fake-var/bin/mettle" "$D" --mettle "$W/fake-flag/bin/mettle" select linux 2>&1)
expect "--mettle beats \$METTLE" "$o" "path=$W/fake-flag/bin/mettle"
P="$W/toolsproj"
mkdir -p "$P"
printf '[package]\nname = "tp"\n' > "$P/manifest.toml"
printf '[tools]\nmettle-linux = "%s"\n' "$W/fake-local/bin/mettle" > "$P/local.toml"
o=$("$D" --root "$P" --mettle "$W/fake-flag/bin/mettle" select linux 2>&1)
expect "--mettle beats mb_tool in mbuild.local.mettle" "$o" "path=$W/fake-flag/bin/mettle"
o=$(METTLE="$W/fake-var/bin/mettle" "$D" --root "$P" select linux 2>&1)
expect "\$METTLE beats mb_tool" "$o" "path=$W/fake-var/bin/mettle"
o=$(PATH="$W/fake-onpath/bin:$PATH" "$D" --root "$P" select linux 2>&1)
expect "mb_tool beats PATH" "$o" "path=$W/fake-local/bin/mettle"
expect "mb_tool: origin" "$o" "source=mb_tool(\"mettle-linux\") in mbuild.local.mettle"
o=$(MBUILD_METTLE_LINUX="$W/fake-env/bin/mettle" "$D" --mettle "$W/fake-flag/bin/mettle" select linux 2>&1)
expect "--mettle beats MBUILD_METTLE_LINUX" "$o" "path=$W/fake-flag/bin/mettle"
o=$(MBUILD_METTLE_LINUX="$W/fake-local/bin/mettle" "$D" --root "$P" select linux 2>&1)
expect "the same value in the variable keeps the origin" "$o" "source=mb_tool(\"mettle-linux\") in mbuild.local.mettle"
o=$(MBUILD_METTLE_LINUX="$W/fake-env/bin/mettle" "$D" --root "$P" select linux 2>&1)
expect "MBUILD_METTLE_LINUX beats mb_tool" "$o" "path=$W/fake-env/bin/mettle"
expect "MBUILD_METTLE_LINUX source" "$o" "source=MBUILD_METTLE_LINUX"
o=$(MBUILD_METTLE_LINUX="$W/nope/mettle" "$D" select linux 2>&1); rc=$?
expect_rc "a missing MBUILD_METTLE_LINUX fails" $rc 1
expect "a missing MBUILD_METTLE_LINUX: message" "$o" "does not exist"
o=$("$D" --root "$P" toolchain list 2>&1)
expect "toolchain list shows the origin" "$o" "$W/fake-local/bin/mettle  (mb_tool(\"mettle-linux\") in mbuild.local.mettle)"
expect "toolchain list: no windows compiler" "$o" "windows  none: no Mettle compiler for windows"

echo "== selection (windows)"
o=$("$D" select windows 2>&1); rc=$?
expect_rc "no windows compiler fails" $rc 1
expect "no windows compiler: help" "$o" 'set MBUILD_METTLE_WINDOWS, or mb_tool("mettle-windows", PATH) in mbuild.local.mettle'
o=$(MBUILD_METTLE_WINDOWS="$W/fake.exe" "$D" select windows 2>&1)
expect "MBUILD_METTLE_WINDOWS" "$o" "path=$W/fake.exe"
expect "windows compiler via wine" "$o" "via_wine=true"
expect "windows: the tool is wine" "$o" "tool=$(command -v wine)"
o=$(METTLE="$W/fake-var/bin/mettle" MBUILD_METTLE_WINDOWS="$W/fake.exe" "$D" --mettle "$W/fake-flag/bin/mettle" select windows 2>&1)
expect "\$METTLE and --mettle are the host's only" "$o" "path=$W/fake.exe"
o=$(MBUILD_METTLE_WINDOWS="$W/fake.exe" MBUILD_WINE=/nonexistent/wine "$D" select windows 2>&1); rc=$?
expect_rc "a missing MBUILD_WINE fails" $rc 1
expect "a missing MBUILD_WINE: message" "$o" "MBUILD_WINE=/nonexistent/wine does not exist"
expect "a missing MBUILD_WINE: help" "$o" "point MBUILD_WINE at the wine executable, or unset it"
o=$(MBUILD_METTLE_WINDOWS="$W/fake.exe" MBUILD_WINE=no-such-wine-xyz "$D" select windows 2>&1); rc=$?
expect_rc "MBUILD_WINE not on PATH fails" $rc 1
expect "MBUILD_WINE not on PATH: message" "$o" "MBUILD_WINE=no-such-wine-xyz is not found on PATH"
o=$(MBUILD_METTLE_WINDOWS="$W/fake.exe" PATH=/nonexistent "$D" select windows 2>&1); rc=$?
expect_rc "no wine on PATH fails" $rc 1
expect "no wine on PATH: message" "$o" "wine not found"
o=$("$D" run-cmd windows /x/y.exe 2>&1)
expect "run-cmd windows uses wine" "$o" "run=WINEDEBUG=-all $(command -v wine) /x/y.exe"
o=$("$D" run-cmd linux /x/y 2>&1)
expect "run-cmd linux runs it directly" "$o" "run=/x/y"

echo "== version, build"
rm -f "$MBUILD_HOME/toolchains/versions.cache"
o=$(MBUILD_METTLE_LINUX="$DEV" "$D" version linux 2>&1)
expect "version linux" "$o" "version=v"
expect "version cached in-process" "$o" "version2=v"
expect "versions.cache holds the id" "$(cat "$MBUILD_HOME/toolchains/versions.cache" 2>/dev/null)" "$DEV|"
o=$(MBUILD_METTLE_LINUX="$DEV" "$D" build-hello linux "$W/hello" 2>&1)
expect "build-hello linux compiles" "$o" "compile=0"
expect "build-hello linux runs" "$o" "run_out=hello from mettle"
expect "build-hello linux exit code" "$o" "run_code=7"

echo "== flag probing"
FL="--safe --check-overflow --pgo-gen"
H="$W/home-probe"
o=$(MBUILD_HOME="$H" MBUILD_METTLE_LINUX="$DEV" "$D" -v unsupported linux $FL --bogus 2>&1)
expect "only --bogus is unsupported" "$o" "unsupported=[--bogus]"
expect "in-process second call" "$o" "unsupported2=[--bogus]"
expect "the first call probes" "$o" "mbuild-probe-missing.mettle"
o=$(MBUILD_HOME="$H" MBUILD_METTLE_LINUX="$DEV" "$D" -v unsupported linux $FL --bogus 2>&1)
expect "second run: same answer" "$o" "unsupported=[--bogus]"
expect_not "second run probes nothing" "$o" "mbuild-probe-missing"
c=$(cat "$H/toolchains/flags.cache" 2>/dev/null)
for f in $FL; do expect "flags.cache: $f supported" "$c" "	$f	1"; done
expect "flags.cache: --bogus unsupported" "$c" "	--bogus	0"
[ -e "$H/tmp/mbuild-probe-missing.mettle" ] && bad "the probe input stays missing" || ok "the probe input stays missing"
o=$(MBUILD_HOME="$H" MBUILD_METTLE_LINUX="$W/fake-env/bin/mettle" "$D" -v unsupported linux --bogus 2>&1)
expect "another compiler identity is probed again" "$o" "mbuild-probe-missing.mettle"
mkdir -p "$W/home-stale/tmp"
echo 'fn main() -> int32 { return 0; }' > "$W/home-stale/tmp/mbuild-probe-missing.mettle"
o=$(MBUILD_HOME="$W/home-stale" MBUILD_METTLE_LINUX="$DEV" "$D" unsupported linux --safe --bogus 2>&1)
expect "a leftover probe input is removed first" "$o" "unsupported=[--bogus]"
H="$W/home-raw"
o=$(MBUILD_HOME="$H" MBUILD_METTLE_LINUX="$DEV" "$D" -v unsupported linux --subsystem windows --bogus 2>&1)
expect "--subsystem windows stays a pair" "$o" "unsupported=[--bogus]"
expect "the pair is probed as a pair" "$o" "mbuild-probe-missing.mettle --subsystem windows --bogus"
expect "the pair is cached as one entry" "$(cat "$H/toolchains/flags.cache")" "	--subsystem windows	1"
o=$(MBUILD_HOME="$H" MBUILD_METTLE_LINUX="$DEV" "$D" unsupported linux 2>&1)
expect "no flags, nothing to probe" "$o" "unsupported=[]"

echo "== minimum Mettle versions"
o=$(MBUILD_METTLE_LINUX="$DEV" "$D" require-min linux v0.99.0 "needs v1.0.0" 2>&1); rc=$?
expect_rc "too old" $rc 1
expect "too old: message" "$o" "require=needs v1.0.0 needs Mettle v0.99.0 or newer; the linux compiler is"
expect "too old: help" "$o" "help: install a newer compiler (mbuild toolchain install)"
o=$(MBUILD_METTLE_LINUX="$DEV" "$D" require-min linux v0.1.0 "needs v0.9.0" 2>&1); rc=$?
expect_rc "new enough" $rc 0
o=$(MBUILD_METTLE_LINUX="$DEV" "$D" require-min linux 0.1 x 2>&1); rc=$?
expect_rc "0.1 normalises and passes" $rc 0
mkdir -p "$W/devc/bin"
printf '#!/bin/sh\necho "mettle dev-build"\n' > "$W/devc/bin/mettle"
chmod +x "$W/devc/bin/mettle"
o=$(MBUILD_HOME="$W/home-dev" MBUILD_METTLE_LINUX="$W/devc/bin/mettle" "$D" -v require-min linux v0.99.0 app 2>&1); rc=$?
expect_rc "a build without a release version passes" $rc 0
expect "and says so with -v" "$o" "not a release"

echo "== mbuild toolchain"
MB="$W/bin/mbuild"
mkdir -p "$W/bin"
"$DEV" --build "$here/src/main.mettle" -o "$MB" >"$W/mbuild-build.log" 2>&1 || { cat "$W/mbuild-build.log"; exit 1; }
export MBUILD_HOME="$W/tchome"
cd "$W/noproj" || exit 1
o=$("$MB" toolchain 2>&1)
expect "first run creates the home" "$o" "Created $W/tchome"
[ -d "$W/tchome/toolchains" ] && ok "first run: the layout" || bad "first run: the layout"
o=$("$MB" toolchain 2>&1)
expect_not "the first-run line comes once" "$o" "Created"

# A fake Mettle checkout: make copies the dev compiler and its runtime into bin/.
FK="$W/fake-mettle"
mkdir -p "$FK/src"
touch "$FK/src/main.c"
ln -s "$DEVDIR/stdlib" "$FK/stdlib"
printf 'bin/\n' > "$FK/.gitignore"
printf 'all:\n\tmkdir -p bin\n\tcp %s bin/mettle\n\trm -rf bin/runtime\n\tcp -r %s/bin/runtime bin/runtime\n' "$DEV" "$DEVDIR" > "$FK/Makefile"
G="git -C $FK -c user.name=t -c user.email=t@t"
$G init -q && $G add -A && $G commit -qm one && $G tag v0.99.0
A=dev-v0.99.0
TH="$MBUILD_HOME/toolchains"
o=$("$MB" toolchain install --from "$FK" 2>&1); rc=$?
expect_rc "install --from a checkout" $rc 0
expect "install --from builds with make" "$o" "Building Mettle v0.99.0 in $FK (make -j"
expect "install --from names it dev-<describe>" "$o" "Installed Mettle $A in $TH/$A"
[ -x "$TH/$A/bin/mettle" ] && [ -d "$TH/$A/stdlib/std" ] && [ -d "$TH/$A/runtime" ] && ok "install --from: release layout" || bad "install --from: release layout" "$(ls -R "$TH" | head -20)"
t=$(cat "$TH/$A/toolchain.toml" 2>/dev/null)
expect "toolchain.toml: source" "$t" "source = \"$FK\""
expect "toolchain.toml: describe" "$t" 'describe = "v0.99.0"'
expect "toolchain.toml: version" "$t" 'version = "v'
o=$("$MB" toolchain install --from "$W/noproj" 2>&1); rc=$?
expect_rc "install --from refuses a non-checkout" $rc 1
expect "install --from: why" "$o" "is not a Mettle source checkout"
o=$("$MB" toolchain install --from "$FK" v0.99.0 2>&1); rc=$?
expect_rc "install takes a version or --from, not both" $rc 2
o=$("$MB" toolchain update 2>&1); rc=$?
expect_rc "update with nothing new" $rc 0
expect "update: fresh" "$o" "Fresh $A ($FK)"
o=$("$MB" toolchain default $A 2>&1); rc=$?
expect_rc "default" $rc 0
expect "default: config.toml" "$(cat "$MBUILD_HOME/config.toml")" "default = \"$A\""
o=$("$MB" toolchain 2>&1)
expect "list marks the selected one" "$o" "* $A"
expect "list tags the default" "$o" "[default]"
expect "list: from the default" "$o" "$TH/$A/bin/mettle  (the default toolchain: $A)"
$G commit -qm two --allow-empty
B="dev-$(git -C "$FK" describe --tags)"
o=$("$MB" toolchain update 2>&1); rc=$?
expect_rc "update rebuilds a moved checkout" $rc 0
expect "update: the new build" "$o" "Installed Mettle $B"
expect "update: the default follows" "$o" "Default Mettle $B"
[ -x "$TH/$A/bin/mettle" ] && ok "update keeps the old build" || bad "update keeps the old build"

echo "== pins and selection order"
PJ="$W/pinproj"
mkdir -p "$PJ/src"
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("pj", "0.1.0");\n}\n\nfn deps() {\n}\n' > "$PJ/mbuild.mettle"
printf 'import "std/io";\n\nfn main() -> int32 {\n  print("pinned\\n");\n  return 0;\n}\n' > "$PJ/src/main.mettle"
cd "$PJ" || exit 1
o=$("$MB" toolchain use $A 2>&1); rc=$?
expect_rc "use pins the project" $rc 0
expect "use writes mb_toolchain" "$(cat mbuild.mettle)" "  mb_toolchain(\"$A\");"
o=$("$MB" -v run 2>&1); rc=$?
expect_rc "a pinned project builds and runs" $rc 0
expect "the pin builds it" "$o" "mettle for linux: $TH/$A/bin/mettle (mb_toolchain(\"$A\") in mbuild.mettle)"
expect "the program runs" "$o" "pinned"
o=$("$MB" toolchain 2>&1)
expect "list: the pin beats the default" "$o" "* $A"
expect "list tags the pin" "$o" "[pinned]"
o=$("$MB" toolchain use $B --local 2>&1); rc=$?
expect_rc "use --local" $rc 0
expect "use --local writes mb_tool" "$(cat mbuild.local.mettle)" "mb_tool(\"mettle-linux\", \"$TH/$B/bin/mettle\");"
o=$("$MB" toolchain 2>&1)
expect "mb_tool beats the pin" "$o" "$TH/$B/bin/mettle  (mb_tool(\"mettle-linux\") in mbuild.local.mettle: $B)"
o=$(METTLE="$W/fake-var/bin/mettle" "$MB" toolchain 2>&1)
expect "\$METTLE beats mb_tool" "$o" "$W/fake-var/bin/mettle  (\$METTLE)"
o=$(METTLE="$W/fake-var/bin/mettle" "$MB" --mettle "$W/fake-flag/bin/mettle" toolchain 2>&1)
expect "--mettle beats \$METTLE" "$o" "$W/fake-flag/bin/mettle  (--mettle)"
rm mbuild.local.mettle
sed -i '/mb_toolchain/d' mbuild.mettle
o=$("$MB" toolchain 2>&1)
expect "the default beats PATH" "$o" "(the default toolchain: $B)"
printf '[toolchain]\n' > "$MBUILD_HOME/config.toml"
o=$(PATH="$W/fake-onpath/bin:$PATH" "$MB" toolchain 2>&1)
expect "then mettle on PATH" "$o" "$W/fake-onpath/bin/mettle  (mettle on PATH)"
"$MB" toolchain default $B >/dev/null 2>&1
o=$("$MB" toolchain use v0.99.7 2>&1); rc=$?
expect_rc "use refuses a toolchain that is not installed" $rc 1
expect "use: the install hint" "$o" "help: mbuild toolchain install v0.99.7"
sed -i 's/^fn project() {$/fn project() {\n  mb_toolchain("v0.99.7");/' mbuild.mettle
o=$("$MB" build 2>&1); rc=$?
expect_rc "a pin to a missing toolchain fails" $rc 1
expect "missing pin: message" "$o" "error: this project pins Mettle v0.99.7 (mb_toolchain in mbuild.mettle), which is not installed"
expect "missing pin: help" "$o" "help: mbuild toolchain install v0.99.7"
o=$("$MB" toolchain 2>&1); rc=$?
expect_rc "toolchain still runs under a missing pin" $rc 0
sed -i '/mb_toolchain/d' mbuild.mettle
o=$("$MB" toolchain remove $B 2>&1); rc=$?
expect_rc "remove" $rc 0
expect "remove drops the default" "$o" "$B was the default toolchain"
[ ! -e "$TH/$B" ] && ok "remove deleted it" || bad "remove deleted it"
o=$("$MB" toolchain remove $B 2>&1); rc=$?
expect_rc "remove of a missing toolchain fails" $rc 1
o=$("$MB" toolchain remove .. 2>&1); rc=$?
expect_rc "remove refuses .." $rc 1
o=$("$MB" toolchain frob 2>&1); rc=$?
expect_rc "unknown subcommand" $rc 2
cd "$W/noproj" || exit 1

echo "== releases (a local fake of the GitHub API)"
REL="$W/rel"
mkdir -p "$REL/dl" "$REL/a/releases/tags" "$REL/b/releases/tags"
for v in v0.99.1 v0.99.2; do
  T="$W/pack/mettle-$v-linux-x64"
  mkdir -p "$T/bin"
  cp "$DEV" "$T/bin/mettle"
  cp -r "$DEVDIR/stdlib" "$T/stdlib"
  ( cd "$W/pack" && tar -czf "$REL/dl/mettle-$v-linux-x64.tar.gz" "mettle-$v-linux-x64" )
done
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$REL" >"$W/http.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
PORT=
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  PORT=$(sed -n 's/.* port \([0-9]*\).*/\1/p' "$W/http.log" | head -1)
  [ -n "$PORT" ] && break
  sleep 0.2
done
[ -n "$PORT" ] || { echo "fake release server did not start"; cat "$W/http.log"; exit 1; }
URL="http://127.0.0.1:$PORT"
# release VERSION DIGEST: the API answer for a release
release() {
  printf '{"tag_name": "%s", "name": "Mettle %s", "assets": [{"name": "mettle-%s-windows-x64.zip", "uploader": {"login": "x"}, "digest": "sha256:00", "browser_download_url": "%s/dl/none.zip"}, {"name": "mettle-%s-linux-x64.tar.gz", "digest": %s, "browser_download_url": "%s/dl/mettle-%s-linux-x64.tar.gz"}]}\n' "$1" "$1" "$1" "$URL" "$1" "$2" "$URL" "$1"
}
GOOD="sha256:$(sha256sum "$REL/dl/mettle-v0.99.1-linux-x64.tar.gz" | cut -d' ' -f1)"
release v0.99.1 "\"$GOOD\"" > "$REL/a/releases/tags/v0.99.1"
release v0.99.2 '"sha256:ffff"' > "$REL/a/releases/tags/v0.99.2"
cp "$REL/a/releases/tags/v0.99.2" "$REL/a/releases/latest"
cp "$REL/a/releases/tags/v0.99.1" "$REL/b/releases/latest"
release v0.99.3 null > "$REL/b/releases/tags/v0.99.3"
cp "$REL/dl/mettle-v0.99.1-linux-x64.tar.gz" "$REL/dl/mettle-v0.99.3-linux-x64.tar.gz"
export MBUILD_METTLE_API="$URL/a"
o=$("$MB" toolchain install 0.99.1 2>&1); rc=$?
expect_rc "install a release" $rc 0
expect "install: Downloading" "$o" "Downloading Mettle v0.99.1 (mettle-v0.99.1-linux-x64.tar.gz)"
[ -x "$TH/v0.99.1/bin/mettle" ] && [ -d "$TH/v0.99.1/stdlib" ] && ok "release layout" || bad "release layout" "$o"
expect "toolchain.toml: a release" "$(cat "$TH/v0.99.1/toolchain.toml")" 'source = "release"'
o=$("$MB" toolchain install v0.99.1 2>&1); rc=$?
expect_rc "install again" $rc 0
expect "install again: already there" "$o" "is already in"
o=$("$MB" toolchain install latest 2>&1); rc=$?
expect_rc "a bad checksum fails" $rc 1
expect "bad checksum: message" "$o" "does not match the release's sha256"
[ ! -e "$TH/v0.99.2" ] && ok "bad checksum: nothing installed" || bad "bad checksum: nothing installed"
left=$(ls -A "$TH" | grep '^\.tmp' || true)
[ -z "$left" ] && ok "no temporary directory left behind" || bad "no temporary directory left behind" "$left"
o=$("$MB" toolchain update 2>&1)
expect "update tells of a newer release" "$o" "Available Mettle v0.99.2 (newest installed: v0.99.1): mbuild toolchain install v0.99.2"
o=$(MBUILD_METTLE_API="$URL/b" "$MB" toolchain update 2>&1)
expect "update: the latest is installed" "$o" "Fresh v0.99.1 is the latest release"
o=$(MBUILD_METTLE_API="$URL/b" "$MB" toolchain install v0.99.3 2>&1); rc=$?
expect_rc "a release without a digest installs" $rc 0
expect "no digest: said" "$o" "the release lists no sha256 for mettle-v0.99.3-linux-x64.tar.gz"
o=$("$MB" toolchain install v0.99.5 2>&1); rc=$?
expect_rc "an unknown release fails" $rc 1
expect "unknown release: message" "$o" "no Mettle release v0.99.5"
o=$("$MB" --offline toolchain install v0.99.4 2>&1); rc=$?
expect_rc "install --offline refuses to download" $rc 1
expect "install --offline says what to run" "$o" "run \`mbuild toolchain install v0.99.4\` without --offline"
o=$("$MB" toolchain install banana 2>&1); rc=$?
expect_rc "install of a non-version fails" $rc 1
o=$(MBUILD_CURL=/nonexistent/curl "$MB" toolchain install v0.99.4 2>&1); rc=$?
expect_rc "a missing MBUILD_CURL fails" $rc 1
expect "a missing MBUILD_CURL: message" "$o" "MBUILD_CURL=/nonexistent/curl does not exist"
o=$(MBUILD_METTLE_API="http://127.0.0.1:1" "$MB" toolchain install v0.99.4 2>&1); rc=$?
expect_rc "no network fails" $rc 1
expect "no network: message" "$o" "cannot reach http://127.0.0.1:1/releases/tags/v0.99.4"
o=$("$MB" toolchain use 0.99.1 2>&1); rc=$?
expect_rc "use outside a project" $rc 1
expect "use outside a project: hint" "$o" "mbuild toolchain default v0.99.1"

echo "== mbuild setup"
SB="$W/sbin"
mkdir -p "$SB" "$W/fakehome"
cp "$MB" "$SB/mbuild"
H2="$W/sethome"
o=$(env -u MBUILD_HOME HOME="$W/fakehome" METTLE="$FK/bin/mettle" "$SB/mbuild" setup --home "$H2" --no-compiler 2>&1); rc=$?
expect_rc "setup --home" $rc 0
expect "setup: the home and why" "$o" "$H2 (--home, saved in $SB/mbuild.home, created)"
expect "setup: mbuild.home" "$(cat "$SB/mbuild.home" 2>/dev/null)" "$H2"
[ -d "$H2/toolchains" ] && ok "setup: the layout" || bad "setup: the layout"
expect "setup finds \$METTLE" "$o" "\$METTLE      $FK/bin/mettle"
expect "setup finds its checkout" "$o" "checkout     $FK"
expect "setup checks curl" "$o" "curl      found"
expect "setup: not on PATH" "$o" "$SB is not on PATH"
expect "setup: the line to add" "$o" "export PATH=\"$SB:\$PATH\""
o=$(env -u MBUILD_HOME HOME="$W/fakehome" "$SB/mbuild" toolchain 2>&1)
expect "mbuild.home sticks" "$o" "($H2/toolchains)"
expect_not "mbuild.home: no first-run line" "$o" "Created"
o=$(env -u MBUILD_HOME HOME="$W/fakehome" PATH="$SB:$PATH" "$SB/mbuild" setup --no-compiler 2>&1)
expect "setup: the home from mbuild.home" "$o" "$H2 (from $SB/mbuild.home)"
expect "setup: on PATH" "$o" "$SB is on PATH"
o=$(env -u MBUILD_HOME HOME="$W/fakehome" METTLE="$FK/bin/mettle" "$SB/mbuild" setup --yes 2>&1); rc=$?
expect_rc "setup --yes installs the found checkout" $rc 0
expect "setup --yes: installed" "$o" "Installed Mettle $B"
expect "setup --yes: the default" "$o" "Default Mettle $B"
o=$(MBUILD_HOME="$W/sethome2" MBUILD_METTLE_API="$URL/b" "$SB/mbuild" setup 2>&1); rc=$?
expect_rc "setup installs the latest release" $rc 0
expect "setup: MBUILD_HOME" "$o" "$W/sethome2 (MBUILD_HOME, created)"
expect "setup: latest" "$o" "Installed Mettle v0.99.1"
expect "setup: made the default" "$(cat "$W/sethome2/config.toml")" 'default = "v0.99.1"'
o=$(MBUILD_HOME="$W/sethome2" MBUILD_METTLE_API="$URL/b" "$SB/mbuild" setup --from "$FK" 2>&1); rc=$?
expect_rc "setup --from" $rc 0
expect "setup --from: the default stays" "$o" "the default toolchain stays v0.99.1"
o=$(MBUILD_HOME="$W/sethome3" MBUILD_METTLE_API="http://127.0.0.1:1" "$SB/mbuild" setup 2>&1); rc=$?
expect_rc "setup offline still succeeds" $rc 0
expect "setup offline: one line" "$o" "note: cannot reach http://127.0.0.1:1/releases/latest (curl exit 7); no compiler installed: run \`mbuild toolchain install latest\` when online"
expect_not "setup offline: no error" "$o" "error:"
[ -d "$W/sethome3/toolchains" ] && ok "setup offline: the layout stays" || bad "setup offline: the layout stays"
rm -f "$SB/mbuild.home"
kill $SRV 2>/dev/null
trap - EXIT

if [ -n "$METTLE_WIN" ]; then
  echo "== under wine"
  o=$(MBUILD_METTLE_WINDOWS="$METTLE_WIN" wine "$DW" select windows 2>&1)
  expect "[wine] windows compiler runs natively" "$o" "via_wine=false"
  o=$(MBUILD_METTLE_LINUX="$DEV" wine "$DW" select linux 2>&1)
  expect "[wine] the linux compiler is a host program" "$o" "unix=true"
  expect "[wine] its tool in Linux form" "$o" "tool=$DEV"
  o=$(MBUILD_METTLE_LINUX="$DEV" wine "$DW" build-hello linux "$W/hello-wine" 2>&1)
  expect "[wine] build-hello linux runs the ELF as a host program" "$o" "run_out=hello from mettle"
  o=$(MBUILD_METTLE_WINDOWS="$METTLE_WIN" wine "$DW" build-hello windows "$W/hello-wine" 2>&1)
  expect "[wine] build-hello windows runs" "$o" "run_out=hello from mettle"
  o=$(MBUILD_METTLE_WINDOWS="$METTLE_WIN" "$D" build-hello windows "$W/hello-win" 2>&1)
  expect "build-hello windows runs under wine" "$o" "run_out=hello from mettle"
  o=$(MBUILD_HOME="$W/home-wine" MBUILD_METTLE_LINUX="$DEV" wine "$DW" -v unsupported linux --safe --bogus 2>&1)
  expect "[wine] probing a host compiler" "$o" "unsupported=[--bogus]"
  o=$(wine "$DW" --root "$P" select linux 2>&1)
  expect "[wine] mb_tool origin" "$o" "source=mb_tool(\"mettle-linux\") in mbuild.local.mettle"
else
  echo "note: wine skipped (METTLE_WIN names no Windows dev compiler)"
fi

echo
echo "toolchain: $pass passed, $failn failed"
[ "$failn" = 0 ]
