#!/bin/sh
# native.sh: C code, link arguments and extern checks of the native module (tests/unit/native_test.mettle).
#   METTLE=dev-compiler sh tests/e2e/native.sh   (scratch: $MBTEST_TMP; gcc, pkg-config + zlib, mingw; METTLE_WIN for wine)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
export METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
W="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/native}"
RT="$(dirname "$METTLE")/runtime"
rm -rf "$W"
mkdir -p "$W"
export WINEDEBUG=-all TMPDIR="$W" MBUILD_HOME="$W/home"
unset MB_VERBOSE MB_PROFILE CC CC_WINDOWS PKG_CONFIG_WINDOWS
[ "${SKIP_WINE:-0}" = 1 ] && unset METTLE_WIN
MINGW=0
command -v x86_64-w64-mingw32-gcc >/dev/null && MINGW=1
WINE=0
[ -n "${METTLE_WIN:-}" ] && WINE=1
WRT="$(dirname "${METTLE_WIN:-/none/x}")/runtime"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/    | /' "$2" | head -40; }
check() { # name, command...
  name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
has() { grep -q -- "$2" "$1"; }    # file, pattern
hasf() { grep -qF -- "$2" "$1"; }  # file, fixed text
hasnt() { ! grep -q -- "$2" "$1"; }
args_of() { sed -n 's/^arg //p' "$1"; }
copies_of() { sed -n 's/^copy //p' "$1"; }

# --- the driver -------------------------------------------------------------------
if out=$(sh "$here/tools/mcheck.sh" "$here/tests/unit/native_test.mettle" 2>&1); then ok "driver builds debug and --release without warnings"; else echo "$out"; exit 1; fi
DRV="$W/mbuild-mcheck/native_test.debug"
WDRV="$W/mbuild-mcheck/native_test.exe"
# wdrv ARGS...: the Windows driver under wine, output without CRs
wdrv() { wine "$WDRV" "$@" 2>&1 | tr -d '\r'; }

F="$W/fx"
sh "$here/tests/fixtures/make-registry.sh" "$F" >/dev/null || { echo "fixtures failed"; exit 1; }
# dep APP NAME VERSION: the fixture package as APP/.mbuild/deps/NAME, frozen manifest included
dep() { mkdir -p "$1/.mbuild/deps"; cp -r "$F/src/$2-$3" "$1/.mbuild/deps/$2"; }

# --- the app: vecmath (C + libm) -> strutil, a vendored library, pkg-config -------
APP="$W/app"
cp -r "$F/app" "$APP"
dep "$APP" vecmath v0.1.0
dep "$APP" strutil v1.0.0
D="$APP/.mbuild/deps"
printf 'app=.\nvecmath=./.mbuild/deps/vecmath\nstrutil=./.mbuild/deps/strutil\n' > "$APP/mettle.deps"
printf 'strutil=../strutil\n' > "$D/vecmath/mettle.deps"
# A second C file in vecmath that does not include vec.h, so a header edit
# must recompile exactly one object.
echo 'int vm_extra(int x) { return x + 1; }' > "$D/vecmath/csrc/extra.c"
mkdir -p "$APP/vendor/lib" "$APP/vendor/src"
echo 'int vend_answer(void) { return 42; }' > "$APP/vendor/src/vend.c"
gcc -shared -fPIC -o "$APP/vendor/lib/libvend.so.1" -Wl,-soname,libvend.so.1 "$APP/vendor/src/vend.c"
ln -sf libvend.so.1 "$APP/vendor/lib/libvend.so"
[ $MINGW = 1 ] && x86_64-w64-mingw32-gcc -shared -static-libgcc -o "$APP/vendor/lib/vend.dll" "$APP/vendor/src/vend.c"
cat > "$APP/manifest.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
vecmath = "v0.1.0"

[link]
libs = ["vend"]
paths = ["vendor/lib"]

[link.linux]
pkgconfig = ["zlib"]
EOF
echo 'export extern fn vend_answer() -> int32 = "vend_answer";' > "$APP/src/vend.mettle"
# A runtime name, and a Win32 name only imported for windows.
echo 'export extern fn rt_strlen(s: cstring) -> int64 = "strlen";' > "$APP/src/rt.mettle"
echo 'export extern fn pw_ticks() -> uint64 = "GetTickCount64";' > "$APP/src/plat_win.mettle"
sed -i 's|^import "strutil/strutil";|import "strutil/strutil";\nimport "vend";\nimport "rt";\nimport "plat_win" if windows;|; s|^  return 0;|  println("vend={vend_answer()}");\n  return 0;|' "$APP/src/main.mettle"

# prepare APP TARGET OUTFILE: the driver's prepare into OUTFILE
prepare() { "$DRV" "$1" "$2" prepare >"$3" 2>&1; }

echo "== linux"
export MB_RUNTIME_DIR="$RT"
prepare "$APP" linux "$W/p1" && ok "prepare linux" || bad "prepare linux" "$W/p1"
check "compiled vecmath (2 C files)" has "$W/p1" "Compiling vecmath (C, 2 files)"
check "linux args name the C library" has "$W/p1" "^arg -lmb_vecmath$"
check "linux args carry [link] libs" has "$W/p1" "^arg -lvend$"
check "linux args carry pkg-config libs" has "$W/p1" "^arg -lz$"
check "linux args carry --rpath \$ORIGIN" has "$W/p1" '^arg \$ORIGIN$'
check "copy list has the C library" has "$W/p1" "^copy .*/libmb_vecmath.so$"
check "copy list has the vendored library" has "$W/p1" "^copy .*/vendor/lib/libvend.so.1$"
OUT="$APP/build/linux/debug"
mkdir -p "$OUT"
( cd "$APP" && "$METTLE" --build src/main.mettle -o build/linux/debug/app $(args_of "$W/p1") ) >"$W/c1.log" 2>&1 \
  && ok "the app compiles with the native args" || bad "the app compiles with the native args" "$W/c1.log"
for f in $(copies_of "$W/p1"); do cp "$f" "$OUT/"; done
"$OUT/app" >"$W/run1.log" 2>&1
check "linux app runs (dot=50.0 len=5.0)" has "$W/run1.log" "dot=50.0 len=5.0"
check "linux app calls the vendored library" has "$W/run1.log" "vend=42"
"$W/mbuild-mcheck/native_test.release" "$APP" linux prepare >"$W/p1r" 2>&1
check "the --release driver prepares the same" cmp -s "$W/p1r" "$(sed '/Compiling/d' "$W/p1" > "$W/p1n"; echo "$W/p1n")"

prepare "$APP" linux "$W/p2"
check "second prepare compiles nothing" hasnt "$W/p2" "Compiling"
check "second prepare: same fingerprint" [ "$(grep '^fp' "$W/p1")" = "$(grep '^fp' "$W/p2")" ]

OBJ="$APP/.mbuild/cache/linux/c/vecmath/csrc"
before_extra=$(stat -c %y "$OBJ/extra.c.o")
sleep 1
touch "$D/vecmath/csrc/include/vec.h"
prepare "$APP" linux "$W/p3"
check "touching vec.h (same content) compiles nothing" hasnt "$W/p3" "Compiling"
echo "/* edited */" >> "$D/vecmath/csrc/include/vec.h"
prepare "$APP" linux "$W/p4"
check "editing vec.h recompiles exactly one file" has "$W/p4" "Compiling vecmath (C, 1 file)"
check "extra.c.o (no vec.h) untouched" [ "$before_extra" = "$(stat -c %y "$OBJ/extra.c.o")" ]
sed -i 's/cflags = \["-O2"\]/cflags = ["-O1"]/' "$D/vecmath/manifest.toml"
prepare "$APP" linux "$W/p5"
check "a cflags change recompiles both files" has "$W/p5" "Compiling vecmath (C, 2 files)"
check "fingerprint changed with the library" [ "$(grep '^fp' "$W/p4")" != "$(grep '^fp' "$W/p5")" ]

cp "$D/vecmath/csrc/extra.c" "$W/extra.c.bak"
echo "this is not C" >> "$D/vecmath/csrc/extra.c"
prepare "$APP" linux "$W/p6" && bad "broken C fails prepare" || ok "broken C fails prepare"
check "broken C: compiler log shown" has "$W/p6" "extra.c"
check "broken C: error names the package" has "$W/p6" "could not compile the C code of vecmath"
cp "$W/extra.c.bak" "$D/vecmath/csrc/extra.c"

"$DRV" "$APP" linux doctor >"$W/d1" 2>&1; rc=$?
check "doctor linux: exit 0 when everything resolves" [ $rc = 0 ]
check "doctor lists vm_dot in the C library" has "$W/d1" "vm_dot.*C library libmb_vecmath.so"
check "doctor lists vend_answer in [link]" has "$W/d1" "vend_answer.*\[link\] library libvend.so"
check "doctor: strlen in the Mettle runtime" has "$W/d1" "strlen .*Mettle runtime"
check "doctor linux skips the windows-only import" hasnt "$W/d1" "GetTickCount64"
check "doctor linux counts 5 externs" has "$W/d1" "linux: 5 externs"

if [ $MINGW = 1 ]; then
  echo "== windows (mingw)"
  export MB_RUNTIME_DIR="$WRT"
  prepare "$APP" windows "$W/w1" && ok "prepare windows" || bad "prepare windows" "$W/w1"
  check "windows args: -lmb_vecmath" has "$W/w1" "^arg -lmb_vecmath$"
  check "windows args: --link-arg" has "$W/w1" "^arg --link-arg$"
  check "windows env: WINEPATH with Z: dirs" has "$W/w1" '^env WINEPATH=Z:\\'
  check "windows copies the DLL" has "$W/w1" "^copy .*/mb_vecmath.dll$"
  check "windows copies the vendored DLL" has "$W/w1" "^copy .*/vendor/lib/vend.dll$"
  check "windows: no -l from pkg-config" hasnt "$W/w1" "^arg -lz$"
  prepare "$APP" windows "$W/w2"
  check "windows second prepare compiles nothing" hasnt "$W/w2" "Compiling"
  "$DRV" "$APP" windows doctor >"$W/wd1" 2>&1; rc=$?
  check "doctor windows: vm_len in the DLL" has "$W/wd1" "vm_len.*C library mb_vecmath.dll"
  check "doctor windows: GetTickCount64 in kernel32" has "$W/wd1" "GetTickCount64 .*Windows default DLL kernel32.dll"
  if [ $WINE = 1 ]; then
    check "doctor windows: exit 0" [ $rc = 0 ]
    check "doctor windows: strlen in the runtime" has "$W/wd1" "strlen .*Mettle runtime"
  fi
else
  echo "note: windows skipped (no x86_64-w64-mingw32-gcc)"
fi

if [ $MINGW = 1 ] && [ $WINE = 1 ]; then
  echo "== wine"
  WOUT="$APP/build/windows/debug"
  mkdir -p "$WOUT"
  WENV=$(sed -n 's/^env //p' "$W/w1")
  ( cd "$APP" && env "$WENV" wine "$METTLE_WIN" --build src/main.mettle -o build/windows/debug/app.exe $(args_of "$W/w1") ) >"$W/wc1.log" 2>&1 \
    && ok "wine mettle.exe compiles the app" || bad "wine mettle.exe compiles the app" "$W/wc1.log"
  for f in $(copies_of "$W/w1"); do cp "$f" "$WOUT/"; done
  ( cd "$WOUT" && wine app.exe ) >"$W/wrun1.log" 2>&1
  check "windows app runs under wine" has "$W/wrun1.log" "dot=50.0 len=5.0"
  check "windows app calls the vendored DLL" has "$W/wrun1.log" "vend=42"
  rm -rf "$APP/.mbuild/cache/windows"
  MB_RUNTIME_DIR="Z:$WRT" wdrv "Z:$APP" windows prepare >"$W/ww1"
  check "wine driver compiled with host mingw" has "$W/ww1" "Compiling vecmath (C, 2 files)"
  check "wine driver: DLL built" [ -f "$APP/.mbuild/cache/windows/lib/mb_vecmath.dll" ]
  check "wine driver: env PATH" has "$W/ww1" "^env PATH=Z:"
  MB_RUNTIME_DIR="Z:$WRT" wdrv "Z:$APP" windows prepare >"$W/ww2"
  check "wine driver: second prepare compiles nothing" hasnt "$W/ww2" "Compiling"
  MB_RUNTIME_DIR="Z:$WRT" wdrv "Z:$APP" linux prepare >"$W/wl1"
  check "wine driver: linux -L in host form" has "$W/wl1" "^arg -L/"
  MB_RUNTIME_DIR="Z:$WRT" wdrv "Z:$APP" windows doctor >"$W/wwd"
  check "wine driver: doctor finds GetTickCount64 in kernel32" has "$W/wwd" "GetTickCount64 .*Windows default DLL kernel32.dll"
  check "wine driver: doctor reads the C library" has "$W/wwd" "vm_dot .*C library mb_vecmath.dll"
  MB_RUNTIME_DIR="Z:$RT" wdrv "Z:$APP" linux doctor >"$W/wld"
  check "wine driver: linux doctor reads ELF through Z:" has "$W/wld" "strlen .*Mettle runtime"
else
  echo "note: wine skipped (METTLE_WIN names no Windows dev compiler)"
fi

echo "== unresolved symbols"
sed -i 's|^fn main() -> int32 {|extern fn vm_missing(x: int32) -> int32 = "vm_missing";\nextern fn cos(x: float64) -> float64 = "cos";\n\nfn main() -> int32 {\n  println("{vm_missing(1)} {cos(0.5)}");|' "$APP/src/main.mettle"
MISSLINE=$(grep -n 'extern fn vm_missing' "$APP/src/main.mettle" | cut -d: -f1)
COSLINE=$(grep -n 'extern fn cos' "$APP/src/main.mettle" | cut -d: -f1)
export MB_RUNTIME_DIR="$RT"
prepare "$APP" linux "$W/p7"
( cd "$APP" && "$METTLE" --build src/main.mettle -o build/linux/debug/app $(args_of "$W/p7") ) >"$W/fail-args.log" 2>&1 \
  && bad "the link fails on vm_missing" || ok "the link fails on vm_missing"
( cd "$APP" && "$METTLE" --build src/main.mettle -o build/linux/debug/app ) >"$W/fail-noargs.log" 2>&1
for v in args noargs; do
  "$DRV" "$APP" linux explain "$W/fail-$v.log" >"$W/ex-$v" 2>&1
  check "explain ($v) names vm_missing's extern" has "$W/ex-$v" "src/main.mettle:$MISSLINE"
  check "explain ($v) names cos's extern" has "$W/ex-$v" "src/main.mettle:$COSLINE"
  check "explain ($v) suggests libm for cos" has "$W/ex-$v" 'mb_link_libs("m");'
  check "explain ($v) notes std/math" has "$W/ex-$v" "std/math"
done
if [ $MINGW = 1 ] && [ $WINE = 1 ]; then
  export MB_RUNTIME_DIR="$WRT"
  ( cd "$APP" && env "$WENV" wine "$METTLE_WIN" --build src/main.mettle -o build/windows/debug/app.exe $(args_of "$W/w1") ) >"$W/fail-win.log" 2>&1
  "$DRV" "$APP" windows explain "$W/fail-win.log" >"$W/ex-win" 2>&1
  check "explain (windows) names vm_missing's extern" has "$W/ex-win" "src/main.mettle:$MISSLINE"
  check "explain (windows): cos only in a C runtime DLL" has "$W/ex-win" "C runtime DLL"
fi
export MB_RUNTIME_DIR="$RT"
"$DRV" "$APP" linux doctor >"$W/d2" 2>&1; rc=$?
check "doctor: non-zero with unresolved externs" [ $rc != 0 ]
check "doctor: vm_missing UNRESOLVED" has "$W/d2" "vm_missing .*UNRESOLVED"
check "doctor: cos UNRESOLVED" has "$W/d2" "cos .*UNRESOLVED"
check "doctor lists every extern for linux (7)" has "$W/d2" "linux: 7 externs"

sed -i 's/pkgconfig = \["zlib"\]/pkgconfig = ["no-such-package-xyz"]/' "$APP/manifest.toml"
prepare "$APP" linux "$W/p8" && bad "unknown pkg-config package fails" || ok "unknown pkg-config package fails"
check "pkg-config failure has a hint" has "$W/p8" "pkg-config does not know 'no-such-package-xyz'"

echo "== symbols"
head -c 5000 /dev/urandom >"$W/garbage.so"
printf 'MZ\001\002' >"$W/short.dll"
head -c 300 /lib/x86_64-linux-gnu/libc.so.6 >"$W/trunc.so"
for f in garbage.so short.dll trunc.so; do
  "$DRV" - linux syms "$W/$f" >/dev/null 2>&1 && ok "symbols survive $f" || bad "symbols survive $f"
done
"$DRV" - linux syms /lib/x86_64-linux-gnu/libm.so.6 | grep -qx cos && ok "symbols: libm.so.6 defines cos" || bad "symbols: libm.so.6 defines cos"
"$DRV" - linux soname /lib/x86_64-linux-gnu/libm.so.6 | grep -qx "soname libm.so.6" && ok "symbols: soname of libm.so.6" || bad "symbols: soname of libm.so.6"
if [ $MINGW = 1 ]; then
  echo 'void *malloc(unsigned long long n) { return 0; }' > "$W/coff.c"
  x86_64-w64-mingw32-gcc -c -o "$W/coff.obj" "$W/coff.c"
  "$DRV" - linux syms "$W/coff.obj" | grep -qx malloc && ok "symbols: a COFF object defines malloc" || bad "symbols: a COFF object defines malloc"
fi

echo "== C calling C across packages"
# capi's C defines a_val (and a header under [c] include); cuser's C includes
# that header and calls a_val; the app calls cuser's u_val.
C="$W/chain"
CD="$C/.mbuild/deps"
mkdir -p "$C/src" "$CD/capi/csrc" "$CD/capi/include" "$CD/cuser/csrc"
cat > "$C/manifest.toml" <<'EOF'
[package]
name = "app"

[dependencies]
cuser = "v0.1.0"

[profile.release]
cflags = ["-DCAPI_EXTRA=100"]
EOF
printf 'cuser=./.mbuild/deps/cuser\ncapi=./.mbuild/deps/capi\n' > "$C/mettle.deps"
cat > "$C/src/main.mettle" <<'EOF'
import "std/io";
import "cuser/cuser";

fn main() -> int32 {
  println("u={u_val()}");
  return 0;
}
EOF
printf '[package]\nname = "capi"\nversion = "v0.1.0"\n\n[c]\nsources = ["csrc"]\ninclude = ["include"]\n' > "$CD/capi/manifest.toml"
printf '#define CAPI_BASE 40\nint a_val(void);\n' > "$CD/capi/include/capi.h"
cat > "$CD/capi/csrc/a.c" <<'EOF'
#include "capi.h"
#ifndef CAPI_EXTRA
#define CAPI_EXTRA 0
#endif
int a_val(void) { return CAPI_BASE + CAPI_EXTRA; }
EOF
echo 'export extern fn a_val() -> int32 = "a_val";' > "$CD/capi/capi.mettle"
printf '[package]\nname = "cuser"\nversion = "v0.1.0"\n\n[dependencies]\ncapi = "v0.1.0"\n\n[c]\nsources = ["csrc"]\n' > "$CD/cuser/manifest.toml"
printf '#include "capi.h"\nint u_val(void) { return a_val() + 2; }\n' > "$CD/cuser/csrc/u.c"
echo 'export extern fn u_val() -> int32 = "u_val";' > "$CD/cuser/cuser.mettle"
# A nested project and a build/ directory: their externs are not the app's.
mkdir -p "$C/examples/nested/src" "$C/build/gen"
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("nested", "0.1.0");\n}\n' > "$C/examples/nested/mbuild.mettle"
echo 'extern fn nested_only_sym() -> int32 = "nested_only_sym";' > "$C/examples/nested/src/main.mettle"
echo 'extern fn build_only_sym() -> int32 = "build_only_sym";' > "$C/build/gen/x.mettle"

export MB_RUNTIME_DIR="$RT"
prepare "$C" linux "$W/cc1" && ok "chain: prepare linux" || bad "chain: prepare linux" "$W/cc1"
check "chain: capi's C is built before cuser's" [ "$(grep -n 'Compiling capi' "$W/cc1" | cut -d: -f1)" -lt "$(grep -n 'Compiling cuser' "$W/cc1" | cut -d: -f1)" ]
check "chain: app link order puts cuser before capi" [ "$(grep -n '^arg -lmb_cuser$' "$W/cc1" | cut -d: -f1)" -lt "$(grep -n '^arg -lmb_capi$' "$W/cc1" | cut -d: -f1)" ]
check "chain: libmb_cuser.so needs libmb_capi.so" sh -c "readelf -d '$C/.mbuild/cache/linux/lib/libmb_cuser.so' | grep -q 'NEEDED.*libmb_capi.so'"
check "chain: libmb_cuser.so has rpath \$ORIGIN" sh -c "readelf -d '$C/.mbuild/cache/linux/lib/libmb_cuser.so' | grep -q 'PATH.*\\\$ORIGIN'"
mkdir -p "$C/build/linux/debug"
( cd "$C" && "$METTLE" --build src/main.mettle -o build/linux/debug/app $(args_of "$W/cc1") ) >"$W/ccb1.log" 2>&1 \
  && ok "chain: the app links" || bad "chain: the app links" "$W/ccb1.log"
for f in $(copies_of "$W/cc1"); do cp "$f" "$C/build/linux/debug/"; done
"$C/build/linux/debug/app" >"$W/ccr1.log" 2>&1
check "chain: linux app runs C calling C (u=42)" has "$W/ccr1.log" "u=42"
"$DRV" "$C" linux doctor >"$W/ccd" 2>&1; rc=$?
check "chain doctor: exit 0" [ $rc = 0 ]
check "chain doctor: u_val in libmb_cuser.so" has "$W/ccd" "u_val .*C library libmb_cuser.so"
check "chain doctor: skips the nested project" hasnt "$W/ccd" "nested_only_sym"
check "chain doctor: skips build/" hasnt "$W/ccd" "build_only_sym"
check "chain doctor: 2 externs" has "$W/ccd" "linux: 2 externs"
echo "/* edited */" >> "$CD/capi/include/capi.h"
prepare "$C" linux "$W/cc2"
check "chain: a dependency header edit recompiles the dependent" has "$W/cc2" "Compiling cuser (C, 1 file)"
# [profile.release] cflags reach every package's C code, in their own cache
# directory, so debug stays fresh.
MB_PROFILE=release "$DRV" "$C" linux prepare >"$W/cc3" 2>&1 && ok "chain: prepare release" || bad "chain: prepare release" "$W/cc3"
check "chain release: copies from lib-release" has "$W/cc3" "^copy .*/lib-release/libmb_capi.so$"
mkdir -p "$C/build/linux/release"
( cd "$C" && "$METTLE" --build src/main.mettle -o build/linux/release/app $(args_of "$W/cc3") ) >"$W/ccb3.log" 2>&1
for f in $(copies_of "$W/cc3"); do cp "$f" "$C/build/linux/release/"; done
"$C/build/linux/release/app" >"$W/ccr3.log" 2>&1
check "chain release: profile cflags applied (u=142)" has "$W/ccr3.log" "u=142"
prepare "$C" linux "$W/cc4"
check "chain: debug still fresh after a release prepare" hasnt "$W/cc4" "Compiling"
if [ $MINGW = 1 ] && [ $WINE = 1 ]; then
  export MB_RUNTIME_DIR="$WRT"
  prepare "$C" windows "$W/cw1" && ok "chain: prepare windows" || bad "chain: prepare windows" "$W/cw1"
  mkdir -p "$C/build/windows/debug"
  CWENV=$(sed -n 's/^env //p' "$W/cw1")
  ( cd "$C" && env "$CWENV" wine "$METTLE_WIN" --build src/main.mettle -o build/windows/debug/app.exe $(args_of "$W/cw1") ) >"$W/cwb1.log" 2>&1 \
    && ok "chain: wine mettle.exe links the app" || bad "chain: wine mettle.exe links the app" "$W/cwb1.log"
  for f in $(copies_of "$W/cw1"); do cp "$f" "$C/build/windows/debug/"; done
  ( cd "$C/build/windows/debug" && wine app.exe ) >"$W/cwr1.log" 2>&1
  check "chain: windows app runs C calling C (u=42)" has "$W/cwr1.log" "u=42"
  # The Linux driver and the wine driver alternating on one project rebuild nothing.
  for tg in linux windows; do
    "$DRV" "$C" $tg prepare >/dev/null 2>&1
    wdrv "Z:$C" $tg prepare >"$W/alt-$tg-w1"
    "$DRV" "$C" $tg prepare >"$W/alt-$tg-l2" 2>&1
    wdrv "Z:$C" $tg prepare >"$W/alt-$tg-w2"
    check "alternating hosts ($tg): wine after linux compiles nothing" hasnt "$W/alt-$tg-w1" "Compiling"
    check "alternating hosts ($tg): linux after wine compiles nothing" hasnt "$W/alt-$tg-l2" "Compiling"
    check "alternating hosts ($tg): same fingerprint" [ "$(grep '^fp' "$W/alt-$tg-l2")" = "$(grep '^fp' "$W/alt-$tg-w2")" ]
  done
fi

echo "== the report lists each library once"
Z="$W/zapp"
mkdir -p "$Z/src"
printf '[package]\nname = "zapp"\n\n[link.windows]\npkgconfig = ["foo"]\n' > "$Z/manifest.toml"
cat > "$Z/src/main.mettle" <<'EOF'
import "std/io";
extern fn bound(n: int64) -> int64 = "compressBound";
fn main() -> int32 {
  println("{bound(100)}");
  return 0;
}
EOF
export MB_RUNTIME_DIR="$RT"
"$DRV" "$Z" linux doctor >"$W/zd" 2>&1
check "report: libz listed once" [ "$(grep -c 'defined in .*libz\.so' "$W/zd")" = 1 ]
check "report: development name with the soname" has "$W/zd" 'defined in .*/libz\.so (libz\.so\.1)$'
check "report: suggests mb_link_libs(\"z\")" has "$W/zd" '^        mb_link_libs("z");$'
check "report: under mb_on" has "$W/zd" '^        mb_on("linux");$'
check "report: no TOML" hasnt "$W/zd" 'libs = \['
printf '#!/bin/sh\necho "-lfoo"\n' > "$W/fake-pc"
chmod +x "$W/fake-pc"
PKG_CONFIG_WINDOWS="$W/fake-pc" "$DRV" "$Z" windows prepare >"$W/zp1" 2>&1
check "PKG_CONFIG_WINDOWS: its -l reaches the windows link" has "$W/zp1" "^arg -lfoo$"
PATH=/usr/bin:/bin "$DRV" "$Z" windows prepare >"$W/zp2" 2>&1
if command -v x86_64-w64-mingw32-pkg-config >/dev/null; then
  check "mingw pkg-config used for windows" hasnt "$W/zp2" "is ignored for the windows target"
else
  check "no windows pkg-config: warned and skipped" has "$W/zp2" "is ignored for the windows target"
fi
if [ $WINE = 1 ]; then
  PKG_CONFIG_WINDOWS="$W/fake-pc" wdrv "Z:$Z" windows prepare >"$W/zp3"
  check "wine driver: PKG_CONFIG_WINDOWS as a host program" has "$W/zp3" "^arg -lfoo$"
fi

echo "== one C symbol in two packages"
A="$W/cdup"
mkdir -p "$A/src"
printf '[package]\nname = "app"\n\n[dependencies]\ncdup1 = "v1.0.0"\ncdup2 = "v1.0.0"\n' > "$A/manifest.toml"
printf 'cdup1=./.mbuild/deps/cdup1\ncdup2=./.mbuild/deps/cdup2\n' > "$A/mettle.deps"
dep "$A" cdup1 v1.0.0
dep "$A" cdup2 v1.0.0
cat > "$A/src/main.mettle" <<'EOF'
import "std/io";
import "cdup1/cdup1";
import "cdup2/cdup2";

fn main() -> int32 {
  println("{cdup1_only()} {cdup2_only()}");
  return 0;
}
EOF
# The interposition this is about, without mbuild: plain shared libraries
# linked -lmb_cdup1 -lmb_cdup2 make cdup2's C call cdup1's copy.
X="$W/control"
mkdir -p "$X"
for n in 1 2; do
  gcc -shared -fPIC -o "$X/libmb_cdup$n.so" -Wl,-soname,libmb_cdup$n.so "$F/src/cdup$n-v1.0.0/dup.c"
done
( cd "$A" && "$METTLE" --build src/main.mettle -o "$X/app" -L"$X" -lmb_cdup1 -lmb_cdup2 --rpath '$ORIGIN' ) >"$X/cc.log" 2>&1
"$X/app" >"$X/run" 2>&1
check "control: without -Bsymbolic cdup2's C calls cdup1's dup_value (1 1)" [ "$(cat "$X/run")" = "1 1" ]
# build_run APP PREPFILE: links src/main.mettle for linux with the prepared
# arguments, copies the libraries beside it and runs it into PREPFILE.run.
build_run() {
  mkdir -p "$1/build/linux/debug"
  ( cd "$1" && "$METTLE" --build src/main.mettle -o build/linux/debug/app $(args_of "$2") ) >"$2.cc" 2>&1 || return 1
  for f in $(copies_of "$2"); do cp "$f" "$1/build/linux/debug/"; done
  "$1/build/linux/debug/app" >"$2.run" 2>&1
}
export MB_RUNTIME_DIR="$RT"
prepare "$A" linux "$W/c1" && ok "cdup: prepare linux" || bad "cdup: prepare linux" "$W/c1"
check "cdup: both C libraries built" [ -f "$A/.mbuild/cache/linux/lib/libmb_cdup1.so" -a -f "$A/.mbuild/cache/linux/lib/libmb_cdup2.so" ]
check "cdup: libraries are linked -Bsymbolic" sh -c "readelf -d '$A/.mbuild/cache/linux/lib/libmb_cdup2.so' | grep -q 'SYMBOLIC'"
check "cdup: no warning without an extern binding dup_value" hasnt "$W/c1" "warning"
check "cdup: dupsyms cached" has "$A/.mbuild/cache/linux/dupsyms" "^dup_value	"
build_run "$A" "$W/c1" && ok "cdup: the app links" || bad "cdup: the app links" "$W/c1.cc"
check "cdup linux: each library calls its own dup_value (1 2)" [ "$(cat "$W/c1.run")" = "1 2" ]
MB_VERBOSE=1 "$DRV" "$A" linux prepare >"$W/c2" 2>&1
check "cdup: second prepare compiles nothing" hasnt "$W/c2" "Compiling"
check "cdup -v: note names both packages" hasf "$W/c2" "the C function dup_value is defined by both cdup1 (libmb_cdup1.so) and cdup2 (libmb_cdup2.so); no extern binds it"
check "cdup -v: still no warning" hasnt "$W/c2" "warning"
# An extern of dup_value in a file nothing imports binds nothing.
echo 'export extern fn stray_dup() -> int32 = "dup_value";' > "$A/.mbuild/deps/cdup2/unused.mettle"
prepare "$A" linux "$W/c2b"
check "cdup: an extern in a file nothing imports does not warn" hasnt "$W/c2b" "warning"
rm -f "$A/.mbuild/deps/cdup2/unused.mettle"
if [ $MINGW = 1 ]; then
  export MB_RUNTIME_DIR="$WRT"
  prepare "$A" windows "$W/cw1" && ok "cdup: prepare windows" || bad "cdup: prepare windows" "$W/cw1"
  check "cdup windows: no warning" hasnt "$W/cw1" "warning"
  check "cdup windows: the DLL exports dup_value" sh -c "'$DRV' - windows syms '$A/.mbuild/cache/windows/lib/mb_cdup2.dll' | grep -qx dup_value"
fi

cat > "$A/src/main.mettle" <<'EOF'
import "std/io";
import "cdup1/cdup1";
import "cdup2/cdup2";

extern fn dup_value() -> int32 = "dup_value";

fn main() -> int32 {
  println("{cdup1_only()} {cdup2_only()} {dup_value()}");
  return 0;
}
EOF
LINE=$(grep -n 'extern fn dup_value' "$A/src/main.mettle" | cut -d: -f1)
export MB_RUNTIME_DIR="$RT"
prepare "$A" linux "$W/d1"
check "dup warning (linux): exact text" hasf "$W/d1" "warning: the C function dup_value is defined by both cdup1 (libmb_cdup1.so) and cdup2 (libmb_cdup2.so); the extern at src/main.mettle:$LINE binds to cdup1's"
check "dup warning (linux): help" hasf "$W/d1" "  help: two packages build the same C code; depend on one package that wraps the library, or make the symbol static/hidden in one of them"
check "dup warning: from the cache too (nothing rebuilt)" hasnt "$W/d1" "Compiling"
build_run "$A" "$W/d1"
check "linux: the extern binds the first library linked (1 2 1)" [ "$(cat "$W/d1.run")" = "1 2 1" ]
if [ $MINGW = 1 ]; then
  export MB_RUNTIME_DIR="$WRT"
  prepare "$A" windows "$W/dw1"
  check "dup warning (windows): names the DLLs" hasf "$W/dw1" "warning: the C function dup_value is defined by both cdup1 (mb_cdup1.dll) and cdup2 (mb_cdup2.dll); the extern at src/main.mettle:$LINE binds to cdup1's"
fi
if [ $MINGW = 1 ] && [ $WINE = 1 ]; then
  mkdir -p "$A/build/windows/debug"
  ( cd "$A" && env "$(sed -n 's/^env //p' "$W/dw1")" wine "$METTLE_WIN" --build src/main.mettle -o build/windows/debug/app.exe $(args_of "$W/dw1") ) >"$W/dw1.cc" 2>&1
  for f in $(copies_of "$W/dw1"); do cp "$f" "$A/build/windows/debug/"; done
  ( cd "$A/build/windows/debug" && wine app.exe ) 2>&1 | tr -d '\r' >"$W/dw1.run"
  check "windows: the extern binds the first DLL linked (1 2 1)" [ "$(cat "$W/dw1.run")" = "1 2 1" ]
  rm -rf "$A/.mbuild/cache/windows"
  MB_RUNTIME_DIR="Z:$WRT" wdrv "Z:$A" windows prepare >"$W/dw2"
  check "wine driver: the same warning" hasf "$W/dw2" "warning: the C function dup_value is defined by both cdup1 (mb_cdup1.dll) and cdup2 (mb_cdup2.dll); the extern at src/main.mettle:$LINE binds to cdup1's"
fi

echo "== a replaced package: its directory is a link"
L="$W/cdup2-local"
cp -r "$F/src/cdup2-v1.0.0" "$L"
sed -i 's/return 2;/return 5;/' "$L/dup.c"
R="$W/repl"
mkdir -p "$R/src"
cp "$A/manifest.toml" "$A/mettle.deps" "$R/"
dep "$R" cdup1 v1.0.0
ln -s "$L" "$R/.mbuild/deps/cdup2"
sed 's/ {dup_value()}//; /extern fn dup_value/d' "$A/src/main.mettle" > "$R/src/main.mettle"
export MB_RUNTIME_DIR="$RT"
prepare "$R" linux "$W/r1" && ok "replace: prepare linux" || bad "replace: prepare linux" "$W/r1"
build_run "$R" "$W/r1"
check "replace: the local copy's C is used (1 5)" [ "$(cat "$W/r1.run")" = "1 5" ]
"$DRV" "$R" linux doctor >"$W/r2" 2>&1
check "replace: externs located in the real directory" hasf "$W/r2" "$L/cdup2.mettle:1"
check "replace: never through the link path" hasnt "$W/r2" ".mbuild/deps/cdup2"
check "replace: depfile names the real source" has "$R/.mbuild/cache/linux/c/cdup2/dup.c.o.d" "$L/dup.c"
prepare "$R" linux "$W/r3"
check "replace: second prepare compiles nothing" hasnt "$W/r3" "Compiling"
sed -i 's/return 5;/return 6;/' "$L/dup.c"
prepare "$R" linux "$W/r4"
check "replace: an edit in the real directory recompiles" has "$W/r4" "Compiling cdup2 (C, 1 file)"
if [ $MINGW = 1 ] && [ $WINE = 1 ]; then
  MB_RUNTIME_DIR="Z:$WRT" wdrv "Z:$R" windows doctor >"$W/r5"
  check "replace under wine: the link is resolved (host readlink)" has "$W/r5" "cdup2-local/cdup2.mettle:1"
  check "replace under wine: C built from the real directory" has "$R/.mbuild/cache/windows/c/cdup2/dup.c.o.d" "cdup2-local/dup.c"
fi

echo "== importing yourself"
S="$W/selfy"
mkdir -p "$S/csrc" "$S/cmd/demo" "$S/.mbuild/deps"
printf '[package]\nname = "selfy"\n\n[c]\nsources = ["csrc"]\n' > "$S/manifest.toml"
echo 'int selfy_val(void) { return 7; }' > "$S/csrc/s.c"
echo 'export extern fn selfy_val() -> int32 = "selfy_val";' > "$S/lib.mettle"
cat > "$S/cmd/demo/main.mettle" <<'EOF'
import "std/io";
import "selfy/lib";

fn main() -> int32 {
  println("selfy={selfy_val()}");
  return 0;
}
EOF
echo "selfy=." > "$S/mettle.deps"
ln -s "$S" "$S/.mbuild/deps/selfy"
prepare "$S" linux "$W/s1" && ok "self import: prepare linux" || bad "self import: prepare linux" "$W/s1"
check "self import: the C library is built once" [ "$(grep -c '^arg -lmb_' "$W/s1")" = 1 ]
check "self import: no second library" [ ! -e "$S/.mbuild/cache/linux/lib/libmb_selfy_2.so" ]
mkdir -p "$S/build"
( cd "$S" && "$METTLE" --build cmd/demo/main.mettle -o build/demo $(args_of "$W/s1") ) >"$W/s1.cc" 2>&1
for f in $(copies_of "$W/s1"); do cp "$f" "$S/build/"; done
check "self import: cmd/demo runs (selfy=7)" [ "$("$S/build/demo" 2>&1)" = "selfy=7" ]
"$DRV" "$S" linux doctor >"$W/s2" 2>&1
check "self import: doctor counts the extern once" has "$W/s2" "linux: 1 extern"

echo
echo "native: $pass passed, $fail failed"
[ $fail = 0 ]
