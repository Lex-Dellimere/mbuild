#!/bin/sh
# toolchain_test.sh: end-to-end tests of src/toolchain.mettle through
# tests/toolchain_driver.mettle, on Linux and under wine.
#
#   tests/toolchain_test.sh            build the driver with tools/mcheck.sh, then test
#   SKIP_BUILD=1 tests/toolchain_test.sh
#
# Everything happens in scratch MBUILD_HOMEs under /tmp/opencode/tctest,
# seeded with a copy of ~/.mbuild/toolchains/v0.17.0 (never modified). One
# real download from GitHub (v0.16.3, both assets) is made; later downloads
# come from a file:// mirror built from it (MBUILD_METTLE_BASE_URL).

set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
REAL_TC="$HOME/.mbuild/toolchains/v0.17.0"
W=/tmp/opencode/tctest
OUT=/tmp/opencode/mcheck
export WINEDEBUG=-all
export PATH=/usr/local/bin:/usr/bin:/bin
unset METTLE MBUILD_METTLE_LINUX MBUILD_METTLE_WINDOWS MBUILD_WINE MBUILD_METTLE_BASE_URL MBUILD_METTLE_LATEST MBUILD_HOME

pass=0
failn=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /'; }

# expect NAME "output" PATTERN: the output contains PATTERN (fixed string).
expect() {
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (wanted: $3)" "$2"; fi
}
expect_not() {
  if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (unwanted: $3)" "$2"; else ok "$1"; fi
}
expect_rc() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (exit $2, wanted $3)"; fi
}

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  built=$("$here/tools/mcheck.sh" "$here/tests/toolchain_driver.mettle") || { printf '%s\n' "$built"; echo "driver build failed"; exit 1; }
  printf '%s\n' "$built"
  if printf '%s' "$built" | grep -q "^\[headrel\] FAILED"; then bad "driver builds with head --release"; else ok "driver builds with head --release"; fi
  if grep -q "warning" "$OUT"/toolchain_driver.head.log "$OUT"/toolchain_driver.headrel.log "$OUT"/toolchain_driver.l017.log "$OUT"/toolchain_driver.w017.log; then
    bad "driver compiles without warnings"
  else
    ok "driver compiles without warnings in all four variants"
  fi
fi
[ -d "$REAL_TC/linux" ] && [ -d "$REAL_TC/windows" ] || { echo "need $REAL_TC"; exit 1; }

rm -rf "$W"
mkdir -p "$W"

# A home holding a copy of v0.17.0 for both OSes.
seed_home() {
  mkdir -p "$1/toolchains"
  cp -r "$REAL_TC" "$1/toolchains/v0.17.0"
}

# Distinct copies of the Linux compiler for $METTLE / PATH / --mettle / env.
for k in onpath env flag var; do
  cp -r "$REAL_TC/linux" "$W/fake-$k"
done
cp -r "$REAL_TC/windows" "$W/fake-winvar"

# A project pinned to v0.16.3, and one without a manifest.
mkdir -p "$W/proj" "$W/noproj"
printf '[package]\nname = "proj"\n\n[toolchain]\nmettle = "v0.16.3"\n' >"$W/proj/mbuild.toml"

# A wine wrapper that logs every start (for the version cache test).
cat >"$W/wine-logged" <<EOF
#!/bin/sh
echo "\$*" >>"$W/wine.log"
exec wine "\$@"
EOF
chmod +x "$W/wine-logged"

# ---------------------------------------------------------------------------
# Real download: v0.16.3 from GitHub, then a file:// mirror built from it.
# ---------------------------------------------------------------------------
NET="$W/home-net"
seed_home "$NET"
D="$OUT/toolchain_driver.l017"
o=$(MBUILD_HOME="$NET" "$D" toolchain install v0.16.3 2>&1); rc=$?
expect_rc "install v0.16.3 from GitHub" $rc 0
expect "install says Downloading" "$o" "Downloading Mettle v0.16.3 for linux"
expect "install fetched windows too (wine present)" "$o" "Installed Mettle v0.16.3 for windows"
[ -x "$NET/toolchains/v0.16.3/linux/bin/mettle" ] && ok "linux layout bin/mettle" || bad "linux layout bin/mettle"
[ -d "$NET/toolchains/v0.16.3/linux/stdlib" ] && ok "linux layout stdlib" || bad "linux layout stdlib"
[ -f "$NET/toolchains/v0.16.3/windows/mettle.exe" ] && ok "windows layout mettle.exe" || bad "windows layout mettle.exe"
[ -d "$NET/toolchains/v0.16.3/windows/runtime" ] && ok "windows layout runtime" || bad "windows layout runtime"
left=$(ls -A "$NET/toolchains" | grep '^\.tmp' || true)
[ -z "$left" ] && ok "no temporary directory left behind" || bad "no temporary directory left behind" "$left"
o=$(MBUILD_HOME="$NET" "$D" toolchain install v0.0.99 -t linux 2>&1); rc=$?
expect_rc "download of a missing release fails" $rc 1
expect "missing release says 404" "$o" "not found (404)"
expect "missing release mentions MBUILD_METTLE_REPO" "$o" "MBUILD_METTLE_REPO=owner/repo"
expect "missing release names the default repo" "$o" "github.com/suidvandiewereld/Mettle/releases"
o=$("$NET/toolchains/v0.16.3/linux/bin/mettle" --version 2>&1)
expect "downloaded linux compiler runs" "$o" "v0.16.3"
o=$(MBUILD_HOME="$NET" "$D" toolchain install latest 2>&1); rc=$?
expect_rc "install latest (GitHub API)" $rc 0
expect "latest resolves to the installed v0.17.0" "$o" "Mettle v0.17.0 for linux is already"

MIRROR="$W/mirror"
mkdir -p "$MIRROR/v0.16.3/mettle-v0.16.3-linux-x64"
cp -r "$NET/toolchains/v0.16.3/linux/." "$MIRROR/v0.16.3/mettle-v0.16.3-linux-x64/"
(cd "$MIRROR/v0.16.3" && tar -czf mettle-v0.16.3-linux-x64.tar.gz mettle-v0.16.3-linux-x64 && rm -rf mettle-v0.16.3-linux-x64)
(cd "$NET/toolchains/v0.16.3/windows" && python3 -m zipfile -c "$MIRROR/v0.16.3/mettle-v0.16.3-windows-x64.zip" mettle.exe stdlib runtime)
export_mirror="file://$MIRROR"

# ---------------------------------------------------------------------------
# Linux host, for both Linux builds of the driver
# ---------------------------------------------------------------------------
linux_suite() {
  D="$1"; L="$2"
  H="$W/home-$L"
  seed_home "$H"
  export MBUILD_HOME="$H"
  ( cd "$W/noproj" || exit 1

  o=$("$D" select linux 2>&1)
  expect "[$L] linux: newest installed when nothing else" "$o" "source=newest installed toolchain v0.17.0"
  expect "[$L] linux: native tool" "$o" "tool=$H/toolchains/v0.17.0/linux/bin/mettle"
  expect "[$L] linux: stdlib dir" "$o" "stdlib=$H/toolchains/v0.17.0/linux/stdlib"
  expect "[$L] linux: runtime dir" "$o" "runtime=$H/toolchains/v0.17.0/linux/runtime"
  expect "[$L] linux: id path|size|mtime" "$o" "id=$H/toolchains/v0.17.0/linux/bin/mettle|10"

  o=$(PATH="$W/fake-onpath/bin:$PATH" "$D" select linux 2>&1)
  expect "[$L] linux: PATH beats installed" "$o" "source=mettle on PATH"
  expect "[$L] linux: PATH compiler path" "$o" "path=$W/fake-onpath/bin/mettle"
  expect "[$L] linux: PATH stdlib" "$o" "stdlib=$W/fake-onpath/stdlib"

  o=$(PATH="$W/fake-onpath/bin:$PATH" METTLE="$W/fake-var/bin/mettle" "$D" select linux 2>&1)
  expect "[$L] linux: \$METTLE beats PATH" "$o" "path=$W/fake-var/bin/mettle"
  expect "[$L] linux: \$METTLE source" "$o" 'source=$METTLE'

  cd "$W/proj" || exit 1
  o=$(METTLE="$W/fake-var/bin/mettle" "$D" --offline select linux 2>&1); rc=$?
  expect_rc "[$L] linux: pinned but missing + --offline fails" $rc 1
  expect "[$L] linux: offline error names the pin" "$o" "Mettle v0.16.3 (pinned in mbuild.toml) is not installed for linux, and --offline forbids"
  expect "[$L] linux: offline hint" "$o" "mbuild toolchain install v0.16.3 -t linux"

  o=$(METTLE="$W/fake-var/bin/mettle" MBUILD_METTLE_BASE_URL="$export_mirror" "$D" select linux 2>&1)
  expect "[$L] linux: pinned version is downloaded" "$o" "Downloading Mettle v0.16.3 for linux (pinned in mbuild.toml)"
  expect "[$L] linux: pin beats \$METTLE" "$o" 'source=[toolchain] mettle = "v0.16.3" in mbuild.toml'
  expect "[$L] linux: pinned path" "$o" "path=$H/toolchains/v0.16.3/linux/bin/mettle"

  o=$(METTLE="$W/fake-var/bin/mettle" "$D" --mettle "$W/fake-flag/bin/mettle" select linux 2>&1)
  expect "[$L] linux: --mettle beats the pin" "$o" "path=$W/fake-flag/bin/mettle"
  o=$(MBUILD_METTLE_LINUX="$W/fake-env/bin/mettle" "$D" --mettle "$W/fake-flag/bin/mettle" select linux 2>&1)
  expect "[$L] linux: MBUILD_METTLE_LINUX beats --mettle" "$o" "path=$W/fake-env/bin/mettle"
  expect "[$L] linux: env source" "$o" "source=MBUILD_METTLE_LINUX"
  o=$(MBUILD_METTLE_LINUX="$W/nope/mettle" "$D" select linux 2>&1); rc=$?
  expect_rc "[$L] linux: bad MBUILD_METTLE_LINUX fails" $rc 1
  expect "[$L] linux: bad env message" "$o" "does not exist"

  # windows target
  o=$("$D" --offline select windows 2>&1); rc=$?
  expect_rc "[$L] windows: pinned but missing + --offline fails" $rc 1
  o=$(MBUILD_METTLE_BASE_URL="$export_mirror" "$D" select windows 2>&1)
  expect "[$L] windows: pinned zip downloaded" "$o" "Downloading Mettle v0.16.3 for windows"
  expect "[$L] windows: pinned path" "$o" "path=$H/toolchains/v0.16.3/windows/mettle.exe"
  expect "[$L] windows: via wine" "$o" "via_wine=true"
  expect "[$L] windows: tool is wine" "$o" "tool=/usr/bin/wine"
  expect "[$L] windows: stdlib" "$o" "stdlib=$H/toolchains/v0.16.3/windows/stdlib"
  o=$("$D" --mettle "$W/fake-flag/bin/mettle" select windows 2>&1)
  expect "[$L] windows: --mettle only applies to the host target" "$o" "path=$H/toolchains/v0.16.3/windows/mettle.exe"
  o=$(MBUILD_METTLE_WINDOWS="$W/fake-winvar/mettle.exe" "$D" select windows 2>&1)
  expect "[$L] windows: MBUILD_METTLE_WINDOWS beats the pin" "$o" "path=$W/fake-winvar/mettle.exe"
  o=$(MBUILD_WINE=/nonexistent/wine "$D" select windows 2>&1); rc=$?
  expect_rc "[$L] windows: without wine fails" $rc 1
  expect "[$L] windows: bad MBUILD_WINE says it does not exist" "$o" "MBUILD_WINE=/nonexistent/wine does not exist"
  expect "[$L] windows: bad MBUILD_WINE hint" "$o" "point MBUILD_WINE at the wine executable, or unset it"
  o=$(MBUILD_WINE=no-such-wine-xyz "$D" select windows 2>&1); rc=$?
  expect_rc "[$L] windows: MBUILD_WINE name not on PATH fails" $rc 1
  expect "[$L] windows: MBUILD_WINE name not on PATH" "$o" "MBUILD_WINE=no-such-wine-xyz is not found on PATH"
  o=$(PATH=/nonexistent "$D" select windows 2>&1); rc=$?
  expect_rc "[$L] windows: no wine on PATH fails" $rc 1
  expect "[$L] windows: wine install hint" "$o" "install wine"
  expect "[$L] windows: wine not found" "$o" "wine not found"
  o=$(MBUILD_CURL=/nonexistent/curl "$D" toolchain install v0.16.1 -t linux 2>&1); rc=$?
  expect_rc "[$L] bad MBUILD_CURL fails" $rc 1
  expect "[$L] bad MBUILD_CURL says it does not exist" "$o" "MBUILD_CURL=/nonexistent/curl does not exist"

  cd "$W/noproj" || exit 1
  o=$("$D" select windows 2>&1)
  expect "[$L] windows: newest installed without a pin" "$o" "path=$H/toolchains/v0.17.0/windows/mettle.exe"
  o=$(METTLE="$W/fake-var/bin/mettle" PATH="$W/fake-onpath/bin:$PATH" "$D" select windows 2>&1)
  expect "[$L] windows: \$METTLE/PATH do not apply to windows" "$o" "path=$H/toolchains/v0.17.0/windows/mettle.exe"

  # version cache: the second process must not start wine
  rm -f "$W/wine.log" "$H/toolchains/versions.cache"
  o=$(MBUILD_WINE="$W/wine-logged" "$D" version windows 2>&1)
  expect "[$L] version windows" "$o" "version=v0.17.0"
  expect "[$L] version cached in-process" "$o" "version2=v0.17.0"
  n1=$(wc -l <"$W/wine.log" 2>/dev/null || echo 0)
  o=$(MBUILD_WINE="$W/wine-logged" "$D" version windows 2>&1)
  expect "[$L] version windows again" "$o" "version=v0.17.0"
  n2=$(wc -l <"$W/wine.log" 2>/dev/null || echo 0)
  [ "$n1" = 1 ] && [ "$n2" = 1 ] && ok "[$L] wine started once over two runs" || bad "[$L] wine started once over two runs (log lines: $n1, $n2)"
  expect "[$L] versions.cache holds the id" "$(cat "$H/toolchains/versions.cache")" "$H/toolchains/v0.17.0/windows/mettle.exe|"
  o=$("$D" version linux 2>&1)
  expect "[$L] version linux" "$o" "version=v0.17.0"

  # build and run hello for both targets
  o=$("$D" build-hello linux "$W/hello-$L" 2>&1)
  expect "[$L] build-hello linux compiles" "$o" "compile=0"
  expect "[$L] build-hello linux runs" "$o" "run_out=hello from mettle"
  expect "[$L] build-hello linux exit code" "$o" "run_code=7"
  o=$("$D" build-hello windows "$W/hello-$L" 2>&1)
  expect "[$L] build-hello windows compiles" "$o" "compile=0"
  expect "[$L] build-hello windows runs under wine" "$o" "run_out=hello from mettle"
  expect "[$L] build-hello windows exit code" "$o" "run_code=7"
  o=$("$D" run-cmd windows /x/y.exe 2>&1)
  expect "[$L] run-cmd windows uses wine" "$o" "run=WINEDEBUG=-all /usr/bin/wine /x/y.exe"
  o=$("$D" run-cmd linux /x/y 2>&1)
  expect "[$L] run-cmd linux direct" "$o" "run=/x/y"

  # no compiler at all
  E="$W/home-empty-$L"
  mkdir -p "$E"
  o=$(MBUILD_HOME="$E" "$D" --offline select linux 2>&1); rc=$?
  expect_rc "[$L] nothing found + --offline fails" $rc 1
  expect "[$L] nothing found message" "$o" "no Mettle compiler for linux found, and --offline forbids"
  o=$(MBUILD_HOME="$E" MBUILD_METTLE_BASE_URL="$export_mirror" MBUILD_METTLE_LATEST=v0.16.3 "$D" select linux 2>&1)
  expect "[$L] nothing found downloads the latest" "$o" "Downloading Mettle v0.16.3 for linux (no compiler found)"
  expect "[$L] downloaded latest source" "$o" "source=latest release v0.16.3 (downloaded)"
  o=$(MBUILD_HOME="$E" "$D" toolchain list 2>&1)
  expect "[$L] list shows the download" "$o" "v0.16.3    linux"
  expect "[$L] list: windows would download" "$o" "windows  none: no Mettle compiler for windows found; the next build downloads"

  # toolchain use / list / remove
  U="$W/use-$L"
  mkdir -p "$U"
  printf '# my app\n[package]\nname = "useme"  # keep\n' >"$U/mbuild.toml"
  o=$("$D" --root "$U" --locked toolchain use v0.16.3 2>&1); rc=$?
  expect_rc "[$L] use --locked refuses" $rc 1
  o=$("$D" --root "$W/noproj" toolchain use v0.16.3 2>&1); rc=$?
  expect_rc "[$L] use without mbuild.toml fails" $rc 1
  o=$("$D" --root "$U" --offline toolchain use 0.16.3 -t linux 2>&1); rc=$?
  expect_rc "[$L] use (installed, offline is fine)" $rc 0
  t=$(cat "$U/mbuild.toml")
  expect "[$L] use wrote the pin" "$t" 'mettle = "v0.16.3"'
  expect "[$L] use kept comments" "$t" 'name = "useme"  # keep'
  expect "[$L] use added [toolchain]" "$t" "[toolchain]"
  o=$("$D" --root "$U" select linux 2>&1)
  expect "[$L] select follows use" "$o" "path=$H/toolchains/v0.16.3/linux/bin/mettle"
  o=$("$D" --root "$U" toolchain list 2>&1)
  expect "[$L] list marks the pin" "$o" "v0.16.3    linux, windows  (pinned in mbuild.toml)"
  expect "[$L] list shows pinned selection" "$o" 'linux    '"$H"'/toolchains/v0.16.3/linux/bin/mettle  ([toolchain] mettle = "v0.16.3" in mbuild.toml)'
  expect "[$L] list shows wine" "$o" "through wine)"
  o=$("$D" --root "$U" toolchain use v0.17.0 2>&1); rc=$?
  expect_rc "[$L] use v0.17.0" $rc 0
  expect "[$L] use replaced the pin" "$(cat "$U/mbuild.toml")" 'mettle = "v0.17.0"'
  expect_not "[$L] use left no old pin" "$(cat "$U/mbuild.toml")" 'v0.16.3'

  o=$("$D" toolchain remove v0.16.3 -t windows 2>&1); rc=$?
  expect_rc "[$L] remove -t windows" $rc 0
  [ ! -e "$H/toolchains/v0.16.3/windows" ] && [ -x "$H/toolchains/v0.16.3/linux/bin/mettle" ] && ok "[$L] remove -t windows kept linux" || bad "[$L] remove -t windows kept linux"
  o=$("$D" --root "$W/proj" toolchain remove v0.16.3 2>&1); rc=$?
  expect_rc "[$L] remove v0.16.3" $rc 0
  expect "[$L] remove warns about the pin" "$o" "still pins Mettle v0.16.3"
  [ ! -e "$H/toolchains/v0.16.3" ] && ok "[$L] remove deleted the version" || bad "[$L] remove deleted the version"
  o=$("$D" toolchain remove v0.16.3 2>&1); rc=$?
  expect_rc "[$L] remove of a missing version fails" $rc 1
  o=$("$D" toolchain remove .. 2>&1); rc=$?
  expect_rc "[$L] remove refuses a non-version" $rc 2
  [ -x "$H/toolchains/v0.17.0/linux/bin/mettle" ] && ok "[$L] v0.17.0 untouched" || bad "[$L] v0.17.0 untouched"
  o=$("$D" --offline toolchain install v0.16.2 -t linux 2>&1); rc=$?
  expect_rc "[$L] install --offline refuses to download" $rc 1
  expect "[$L] install --offline says what to run" "$o" "run \`mbuild toolchain install v0.16.2 -t linux\` without --offline"
  [ ! -e "$H/toolchains/v0.16.2" ] && ok "[$L] offline install left nothing" || bad "[$L] offline install left nothing"
  o=$("$D" toolchain install banana 2>&1); rc=$?
  expect_rc "[$L] install of a non-version fails" $rc 1
  o=$("$D" toolchain frob 2>&1); rc=$?
  expect_rc "[$L] unknown subcommand" $rc 2
  ) | tee "$W/suite-$L.log"
  unset MBUILD_HOME
}

linux_suite "$OUT/toolchain_driver.l017" l017
linux_suite "$OUT/toolchain_driver.head" head

# ---------------------------------------------------------------------------
# Windows under wine
# ---------------------------------------------------------------------------
DW="$OUT/toolchain_driver.exe"
WH="$W/home-wine"
seed_home "$WH"
cd "$W/noproj" || exit 1
export MBUILD_HOME="$WH"
(
o=$(wine "$DW" select windows 2>&1)
expect "[wine] windows: native" "$o" "via_wine=false"
expect "[wine] windows: unix=false" "$o" "unix=false"
expect "[wine] windows: path in Windows form" "$o" "path=Z:$WH/toolchains/v0.17.0/windows/mettle.exe"
expect "[wine] windows: stdlib readable" "$o" "stdlib_ok=true"
o=$(wine "$DW" select linux 2>&1)
expect "[wine] linux: host program" "$o" "unix=true"
expect "[wine] linux: tool in Linux form" "$o" "tool=$WH/toolchains/v0.17.0/linux/bin/mettle"
expect "[wine] linux: stdlib in Windows form" "$o" "stdlib=Z:$WH/toolchains/v0.17.0/linux/stdlib"
expect "[wine] linux: stdlib readable" "$o" "stdlib_ok=true"
o=$(MBUILD_HOME="Z:$(echo "$WH" | tr / '\\')" wine "$DW" select linux 2>&1)
expect "[wine] MBUILD_HOME in Windows form" "$o" "tool=$WH/toolchains/v0.17.0/linux/bin/mettle"
o=$(MBUILD_METTLE_LINUX="$W/fake-env/bin/mettle" wine "$DW" select linux 2>&1)
expect "[wine] MBUILD_METTLE_LINUX (Linux path)" "$o" "tool=$W/fake-env/bin/mettle"
expect "[wine] MBUILD_METTLE_LINUX source" "$o" "source=MBUILD_METTLE_LINUX"
o=$(MBUILD_METTLE_LINUX="$W/fake-winvar/mettle.exe" wine "$DW" select linux 2>&1); rc=$?
expect_rc "[wine] a Windows compiler for linux is refused" $rc 1
o=$(MBUILD_METTLE_WINDOWS="$W/fake-winvar/mettle.exe" wine "$DW" select windows 2>&1)
expect "[wine] MBUILD_METTLE_WINDOWS (Linux path)" "$o" "path=Z:$W/fake-winvar/mettle.exe"
o=$(wine "$DW" --mettle "$W/fake-winvar/mettle.exe" select windows 2>&1)
expect "[wine] --mettle for the host target" "$o" "source=--mettle"

rm -f "$WH/toolchains/versions.cache"
o=$(wine "$DW" version linux 2>&1)
expect "[wine] version linux" "$o" "version=v0.17.0"
expect "[wine] versions.cache written" "$(cat "$WH/toolchains/versions.cache")" "Z:$WH/toolchains/v0.17.0/linux/bin/mettle|"
o=$(wine "$DW" version windows 2>&1)
expect "[wine] version windows" "$o" "version2=v0.17.0"

o=$(wine "$DW" build-hello linux "$W/hello-wine" 2>&1)
expect "[wine] build-hello linux compiles" "$o" "compile=0"
expect "[wine] build-hello linux runs the ELF as a host program" "$o" "run_out=hello from mettle"
expect "[wine] build-hello linux exit code" "$o" "run_code=7"
file "$W/hello-wine/hello_linux" 2>/dev/null | grep -q ELF && ok "[wine] hello_linux is an ELF" || bad "[wine] hello_linux is an ELF"
o=$(wine "$DW" build-hello windows "$W/hello-wine" 2>&1)
expect "[wine] build-hello windows compiles" "$o" "compile=0"
expect "[wine] build-hello windows runs" "$o" "run_out=hello from mettle"
o=$(wine "$DW" run-cmd linux "$W/x/prog" 2>&1)
expect "[wine] run-cmd linux: host path" "$o" "run=$W/x/prog"

o=$(wine "$DW" toolchain list 2>&1)
expect "[wine] list linux" "$o" "(newest installed toolchain v0.17.0, as a host program)"
expect "[wine] list windows" "$o" "windows  Z:$WH/toolchains/v0.17.0/windows/mettle.exe  (newest installed toolchain v0.17.0)"

o=$(wine "$DW" --offline toolchain install v0.16.3 2>&1); rc=$?
expect_rc "[wine] install --offline refuses" $rc 1
o=$(MBUILD_METTLE_BASE_URL="$export_mirror" wine "$DW" toolchain install v0.16.3 2>&1); rc=$?
expect_rc "[wine] install from the mirror (host curl, tar, unzip)" $rc 0
expect "[wine] install default targets windows+linux" "$o" "Installed Mettle v0.16.3 for linux"
[ -f "$WH/toolchains/v0.16.3/windows/mettle.exe" ] && [ -x "$WH/toolchains/v0.16.3/linux/bin/mettle" ] && ok "[wine] installed layout" || bad "[wine] installed layout"
o=$(wine "$DW" --root "$W/proj" select windows 2>&1)
expect "[wine] pinned windows" "$o" "path=Z:$WH/toolchains/v0.16.3/windows/mettle.exe"
o=$(wine "$DW" --root "$W/proj" build-hello linux "$W/hello-wine16" 2>&1)
expect "[wine] pinned v0.16.3 linux builds and runs" "$o" "run_out=hello from mettle"
o=$(wine "$DW" toolchain remove v0.16.3 2>&1); rc=$?
expect_rc "[wine] remove" $rc 0
[ ! -e "$WH/toolchains/v0.16.3" ] && ok "[wine] remove deleted it" || bad "[wine] remove deleted it"
) | tee "$W/suite-wine.log"
unset MBUILD_HOME

[ -x "$REAL_TC/linux/bin/mettle" ] && [ -f "$REAL_TC/windows/mettle.exe" ] && ok "real ~/.mbuild/toolchains/v0.17.0 intact" || bad "real ~/.mbuild/toolchains/v0.17.0 intact"

p=$(cat "$W"/suite-*.log | grep -c '^PASS')
f=$(cat "$W"/suite-*.log | grep -c '^FAIL')
pass=$((pass + p)); failn=$((failn + f))
echo "toolchain_test: $pass passed, $failn failed"
[ "$failn" = 0 ]
