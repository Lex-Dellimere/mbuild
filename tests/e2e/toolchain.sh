#!/bin/sh
# toolchain.sh: compiler selection, flag probing, minimum versions and `mbuild toolchain` (tests/unit/toolchain_test.mettle).
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
unset METTLE MBUILD_METTLE_LINUX MBUILD_METTLE_WINDOWS MBUILD_WINE MBUILD_METTLE_BASE_URL MBUILD_METTLE_LATEST MBUILD_HOME MBUILD_CURL

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
expect "no compiler: help" "$o" "help: build ../Mettle (make) and put bin/mettle on PATH, or set MBUILD_METTLE_LINUX"
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
expect "mb_tool in mbuild.local.mettle beats --mettle" "$o" "path=$W/fake-local/bin/mettle"
expect "mb_tool: origin" "$o" "source=mb_tool(\"mettle-linux\") in mbuild.local.mettle"
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
expect "too old: help" "$o" "help: build a newer compiler from ../Mettle"
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
TC="$MBUILD_HOME/toolchains/v0.99.0/linux"
mkdir -p "$TC/bin"
cp "$DEV" "$TC/bin/mettle"
U="$W/use"
mkdir -p "$U"
printf '[package]\nname = "u"\n' > "$U/manifest.toml"
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("u", "0.1.0");\n}\n' > "$U/mbuild.mettle"
o=$("$D" --root "$U" toolchain use 0.99.0 2>&1); rc=$?
expect_rc "use an installed release" $rc 0
expect "use writes mb_tool" "$(cat "$U/mbuild.local.mettle" 2>/dev/null)" "mb_tool(\"mettle-linux\", \"$TC/bin/mettle\");"
o=$("$D" toolchain list 2>&1)
expect "list shows the installed release" "$o" "v0.99.0"
o=$("$D" toolchain remove v0.99.0 2>&1); rc=$?
expect_rc "remove" $rc 0
[ ! -e "$MBUILD_HOME/toolchains/v0.99.0" ] && ok "remove deleted the release" || bad "remove deleted the release"
o=$("$D" toolchain remove v0.99.0 2>&1); rc=$?
expect_rc "remove of a missing release fails" $rc 1
o=$("$D" toolchain remove .. 2>&1); rc=$?
expect_rc "remove refuses a non-version" $rc 2
o=$("$D" --offline toolchain install v0.16.2 -t linux 2>&1); rc=$?
expect_rc "install --offline refuses to download" $rc 1
expect "install --offline says what to run" "$o" "run \`mbuild toolchain install v0.16.2 -t linux\` without --offline"
expect "install warns about old releases" "$o" "releases up to v0.17.0 cannot build current projects"
o=$("$D" toolchain install banana 2>&1); rc=$?
expect_rc "install of a non-version fails" $rc 1
o=$(MBUILD_CURL=/nonexistent/curl "$D" toolchain install v0.16.1 -t linux 2>&1); rc=$?
expect_rc "a missing MBUILD_CURL fails" $rc 1
expect "a missing MBUILD_CURL: message" "$o" "MBUILD_CURL=/nonexistent/curl does not exist"
# A release from a file:// mirror (MBUILD_METTLE_BASE_URL), laid out as GitHub's assets.
M="$W/mirror/v0.99.1/mettle-v0.99.1-linux-x64"
mkdir -p "$M/bin"
cp "$DEV" "$M/bin/mettle"
cp -r "$DEVDIR/stdlib" "$M/stdlib"
( cd "$W/mirror/v0.99.1" && tar -czf mettle-v0.99.1-linux-x64.tar.gz mettle-v0.99.1-linux-x64 && rm -rf mettle-v0.99.1-linux-x64 )
o=$(MBUILD_METTLE_BASE_URL="file://$W/mirror" "$D" toolchain install v0.99.1 -t linux 2>&1); rc=$?
expect_rc "install from a mirror" $rc 0
expect "install says Downloading" "$o" "Downloading Mettle v0.99.1 for linux"
[ -x "$MBUILD_HOME/toolchains/v0.99.1/linux/bin/mettle" ] && [ -d "$MBUILD_HOME/toolchains/v0.99.1/linux/stdlib" ] && ok "installed layout" || bad "installed layout" "$o"
left=$(ls -A "$MBUILD_HOME/toolchains" | grep '^\.tmp' || true)
[ -z "$left" ] && ok "no temporary directory left behind" || bad "no temporary directory left behind" "$left"
o=$("$D" toolchain frob 2>&1); rc=$?
expect_rc "unknown subcommand" $rc 2

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
