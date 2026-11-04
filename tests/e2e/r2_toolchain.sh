#!/bin/sh
# r2_toolchain.sh: round-2 toolchain tests (DESIGN.md 12.21 Group T):
# flag probing with flags.cache (tc_unsupported), minimum Mettle versions
# (tc_require_minimum) and [tools] origins, through tests/toolchain_driver.mettle.
#
#   tests/r2_toolchain.sh            build the driver with tools/mcheck.sh, then test
#   SKIP_BUILD=1 tests/r2_toolchain.sh
#
# Compilers: head (../Mettle/bin/mettle) and the v0.17.0 releases in
# ~/.mbuild/toolchains/v0.17.0 (Linux natively, Windows through wine). Each
# case uses a fresh MBUILD_HOME under /tmp/opencode/r2tc.

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
HEAD="$(realpath "${METTLE_HEAD:-$here/../Mettle/bin/mettle}")"
REAL_TC="$HOME/.mbuild/toolchains/v0.17.0"
L017="$REAL_TC/linux/bin/mettle"
W017="$REAL_TC/windows/mettle.exe"
W=/tmp/opencode/r2tc
OUT=/tmp/opencode/mcheck
export WINEDEBUG=-all
export PATH=/usr/local/bin:/usr/bin:/bin
unset METTLE MBUILD_METTLE_LINUX MBUILD_METTLE_WINDOWS MBUILD_WINE MBUILD_HOME

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

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  built=$("$here/tools/mcheck.sh" "$here/tests/unit/toolchain_test.mettle") || { printf '%s\n' "$built"; echo "driver build failed"; exit 1; }
  printf '%s\n' "$built"
  if printf '%s' "$built" | grep -q "(0 warnings)" && ! printf '%s' "$built" | grep -qv "(0 warnings)"; then
    ok "driver builds warning-free with head, head --release, v0.17.0 Linux and Windows"
  else
    bad "driver builds warning-free with head, head --release, v0.17.0 Linux and Windows"
  fi
fi
[ -x "$HEAD" ] && [ -x "$L017" ] && [ -f "$W017" ] || { echo "need $HEAD, $L017 and $W017"; exit 1; }

rm -rf "$W"
mkdir -p "$W/noproj"
cd "$W/noproj" || exit 1

DL="$OUT/toolchain_driver.l017"
DH="$OUT/toolchain_driver.head"
DW="$OUT/toolchain_driver.exe"
FL="--safe --check-overflow --pgo-gen"

# probe_case LABEL HOME "driver command..." TARGET WANT: two processes; the
# first probes, the second (and the in-process second call) must not.
probe_case() {
  label="$1"; home="$2"; run="$3"; target="$4"; want="$5"
  rm -rf "$home"
  o=$(MBUILD_HOME="$home" $run -v unsupported "$target" $FL 2>&1)
  expect "[$label] unsupported" "$o" "unsupported=[$want]"
  expect "[$label] in-process second call" "$o" "unsupported2=[$want]"
  expect "[$label] first call probes" "$o" "mbuild-probe-missing.mettle"
  n=$(printf '%s\n' "$o" | grep -c "mbuild-probe-missing.mettle --")
  o=$(MBUILD_HOME="$home" $run -v unsupported "$target" $FL 2>&1)
  expect "[$label] second run unsupported" "$o" "unsupported=[$want]"
  expect_not "[$label] second run runs no probe" "$o" "mbuild-probe-missing"
  expect_not "[$label] second run starts no compiler" "$o" "probing"
  c=$(cat "$home/toolchains/flags.cache" 2>/dev/null)
  for f in $FL; do
    if printf '%s' "$want" | grep -qF -- "$f"; then v=0; else v=1; fi
    printf '%s\n' "$c" | grep -q "	$f	$v\$" && ok "[$label] flags.cache: $f $v" || bad "[$label] flags.cache: $f $v" "$c"
  done
  [ -e "$home/tmp/mbuild-probe-missing.mettle" ] && bad "[$label] probe input stays missing" || ok "[$label] probe input stays missing"
  echo "     ($label: $n probe run(s) the first time)"
}

# ---------------------------------------------------------------------------
# Linux host
# ---------------------------------------------------------------------------
H="$W/home"
MBUILD_METTLE_LINUX="$HEAD" probe_case "head linux" "$H-head" "$DL" linux ""
MBUILD_METTLE_LINUX="$L017" probe_case "v0.17.0 linux" "$H-l017" "$DL" linux "--check-overflow, --pgo-gen"
MBUILD_METTLE_LINUX="$L017" probe_case "v0.17.0 linux (head-built driver)" "$H-l017h" "$DH" linux "--check-overflow, --pgo-gen"
MBUILD_METTLE_WINDOWS="$W017" probe_case "v0.17.0 windows via wine" "$H-w017" "$DL" windows "--check-overflow, --pgo-gen"

# Cached answers are per compiler identity: another compiler probes again.
o=$(MBUILD_HOME="$H-l017" MBUILD_METTLE_LINUX="$HEAD" "$DL" -v unsupported linux $FL 2>&1)
expect "[cache] another compiler is probed" "$o" "mbuild-probe-missing.mettle"
expect "[cache] head after v0.17.0 in one cache" "$o" "unsupported=[]"
o=$(MBUILD_HOME="$H-l017" MBUILD_METTLE_LINUX="$L017" "$DL" -v unsupported linux $FL 2>&1)
expect "[cache] v0.17.0 answers still cached" "$o" "unsupported=[--check-overflow, --pgo-gen]"
expect_not "[cache] v0.17.0 not probed again" "$o" "mbuild-probe-missing"

# The probe input is guaranteed missing, even when something left it there.
mkdir -p "$H-stale/tmp"
echo 'fn main() -> int32 { return 0; }' >"$H-stale/tmp/mbuild-probe-missing.mettle"
o=$(MBUILD_HOME="$H-stale" MBUILD_METTLE_LINUX="$L017" "$DL" unsupported linux --check-overflow --safe 2>&1)
expect "[stale] a leftover probe input is removed first" "$o" "unsupported=[--check-overflow]"

# Raw flags: value pairs stay pairs.
for pair in "l017 linux $L017" "w017 windows $W017"; do
  set -- $pair
  hm="$H-raw-$1"; rm -rf "$hm"
  if [ "$2" = linux ]; then v=MBUILD_METTLE_LINUX; else v=MBUILD_METTLE_WINDOWS; fi
  o=$(env MBUILD_HOME="$hm" "$v=$3" "$DL" -v unsupported "$2" --subsystem windows --bogus 2>&1)
  expect "[raw $1] --subsystem windows --bogus" "$o" "unsupported=[--bogus]"
  expect "[raw $1] the pair is probed as a pair" "$o" "mbuild-probe-missing.mettle --subsystem windows --bogus"
  expect "[raw $1] the pair is cached as one entry" "$(cat "$hm/toolchains/flags.cache")" "	--subsystem windows	1"
  o=$(env MBUILD_HOME="$hm" "$v=$3" "$DL" unsupported "$2" --pgo-use=pgo/a.prof --debug-format dwarf --linker internal 2>&1)
  expect "[raw $1] --pgo-use=F rejected, --debug-format F / --linker M accepted" "$o" "unsupported=[--pgo-use=pgo/a.prof]"
done
hm="$H-raw-head"; rm -rf "$hm"
o=$(MBUILD_HOME="$hm" MBUILD_METTLE_LINUX="$HEAD" "$DL" unsupported linux --pgo-use=pgo/a.prof --check-proofs --report-effects --bogus 2>&1)
expect "[raw head] only --bogus is rejected" "$o" "unsupported=[--bogus]"
o=$(MBUILD_HOME="$hm" MBUILD_METTLE_LINUX="$L017" "$DL" unsupported linux --check-proofs --check-effects --check-deadlines --check-tasks --assume-no-signed-overflow --report-effects --report-proofs --record-trace --check-purity-fault -O --release -s -g --native-heap --verify --pgo --no-crash-report --ml-opt --ml-opt-speculative --explain --explain-all --explain-json --simd-report --prelude --static --musl --error-format=json 2>&1)
expect "[table v0.17.0] head-only flags rejected, common ones accepted" "$o" "unsupported=[--check-proofs, --check-effects, --check-deadlines, --check-tasks, --assume-no-signed-overflow, --report-effects, --report-proofs, --record-trace, --check-purity-fault]"
o=$(MBUILD_HOME="$hm" MBUILD_METTLE_LINUX="$L017" "$DL" unsupported linux 2>&1)
expect "[raw] no flags, nothing to probe" "$o" "unsupported=[]"

# tc_require_minimum
o=$(MBUILD_HOME="$H-l017" MBUILD_METTLE_LINUX="$L017" "$DL" require-min linux v0.99.0 "github.com/demo/needs v1.0.0" 2>&1); rc=$?
expect_rc "[minimum] too old" $rc 1
expect "[minimum] message" "$o" "require=github.com/demo/needs v1.0.0 needs Mettle v0.99.0 or newer; the linux compiler is v0.17.0 ($L017)"
expect "[minimum] help" "$o" "  help: run \`mbuild toolchain use v0.99.0\`"
o=$(MBUILD_HOME="$H-l017" MBUILD_METTLE_LINUX="$L017" "$DL" require-min linux v0.17.0 "github.com/demo/needs v1.0.0" 2>&1); rc=$?
expect_rc "[minimum] v0.17.0 is enough" $rc 0
expect "[minimum] empty answer" "$o" "require="
o=$(MBUILD_HOME="$H-l017" MBUILD_METTLE_LINUX="$L017" "$DL" require-min linux 0.16 "x" 2>&1); rc=$?
expect_rc "[minimum] 0.16 normalises and passes" $rc 0
o=$(MBUILD_HOME="$H-w017" MBUILD_METTLE_WINDOWS="$W017" "$DL" require-min windows v0.18.0 "app" 2>&1); rc=$?
expect_rc "[minimum] windows too old" $rc 1
expect "[minimum] windows message" "$o" "require=app needs Mettle v0.18.0 or newer; the windows compiler is v0.17.0 ($W017)"
# A development build (version not a release) passes with a -v note.
mkdir -p "$W/devc/bin"
printf '#!/bin/sh\necho "mettle dev-build"\n' >"$W/devc/bin/mettle"; chmod +x "$W/devc/bin/mettle"
o=$(MBUILD_HOME="$W/home-dev" MBUILD_METTLE_LINUX="$W/devc/bin/mettle" "$DL" -v require-min linux v0.99.0 app 2>&1); rc=$?
expect_rc "[minimum] development build passes" $rc 0
expect "[minimum] development build -v note" "$o" "not a release"

# [tools] origins (T-3): mbuild.local.toml, the variable wins when it differs.
P="$W/toolsproj"; mkdir -p "$P"
printf '[package]\nname = "tp"\n' >"$P/mbuild.toml"
printf '[tools]\nmettle-linux = "%s"\n' "$HEAD" >"$P/mbuild.local.toml"
o=$(MBUILD_HOME="$H-head" "$DL" --root "$P" select linux 2>&1)
expect "[tools] local mettle-linux used" "$o" "path=$HEAD"
expect "[tools] origin named" "$o" "source=[tools] mettle-linux (mbuild.local.toml)"
o=$(MBUILD_HOME="$H-head" MBUILD_METTLE_LINUX="$HEAD" "$DL" --root "$P" select linux 2>&1)
expect "[tools] same value already applied keeps the origin" "$o" "source=[tools] mettle-linux (mbuild.local.toml)"
o=$(MBUILD_HOME="$H-head" MBUILD_METTLE_LINUX="$L017" "$DL" --root "$P" select linux 2>&1)
expect "[tools] the variable wins" "$o" "path=$L017"
expect "[tools] variable source" "$o" "source=MBUILD_METTLE_LINUX"
o=$(MBUILD_HOME="$H-head" "$DL" --root "$P" toolchain list 2>&1)
expect "[tools] toolchain list shows the origin" "$o" "$HEAD  ([tools] mettle-linux (mbuild.local.toml))"

# ---------------------------------------------------------------------------
# Under wine: the Windows compiler natively, the Linux ones as host programs
# ---------------------------------------------------------------------------
probe_case "wine: v0.17.0 windows natively" "$H-wine" "env MBUILD_METTLE_WINDOWS=$W017 wine $DW" windows "--check-overflow, --pgo-gen"
probe_case "wine: v0.17.0 linux as host program" "$H-wine-l" "env MBUILD_METTLE_LINUX=$L017 wine $DW" linux "--check-overflow, --pgo-gen"
probe_case "wine: head linux as host program" "$H-wine-h" "env MBUILD_METTLE_LINUX=$HEAD wine $DW" linux ""
o=$(MBUILD_HOME="$H-wine" MBUILD_METTLE_WINDOWS="$W017" wine "$DW" unsupported windows --subsystem windows --bogus 2>&1)
expect "[wine] raw pair on windows" "$o" "unsupported=[--bogus]"
o=$(MBUILD_HOME="$H-wine-l" MBUILD_METTLE_LINUX="$L017" wine "$DW" require-min linux v0.99.0 "github.com/demo/needs v1.0.0" 2>&1); rc=$?
expect_rc "[wine] minimum too old" $rc 1
expect "[wine] minimum message" "$o" "require=github.com/demo/needs v1.0.0 needs Mettle v0.99.0 or newer; the linux compiler is v0.17.0"
o=$(MBUILD_HOME="$H-head" wine "$DW" --root "$P" select linux 2>&1)
expect "[wine tools] origin named" "$o" "source=[tools] mettle-linux (mbuild.local.toml)"
expect "[wine tools] host program" "$o" "tool=$HEAD"

echo "r2_toolchain: $pass passed, $failn failed"
[ "$failn" = 0 ]
