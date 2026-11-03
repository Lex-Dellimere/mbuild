#!/bin/sh
# native_test.sh: end-to-end test of src/native.mettle and src/symbols.mettle
# through tests/native_driver.mettle, against the git fixtures.
#
#   tests/native_test.sh [WORKDIR]        (default /tmp/opencode/native-test)
#
# Needs: gcc, x86_64-w64-mingw32-gcc, pkg-config + zlib, wine, the head
# compiler (../Mettle/bin/mettle) and the v0.17.0 toolchains under
# ~/.mbuild/toolchains.

set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
W="${1:-/tmp/opencode/native-test}"
HEAD="${METTLE_HEAD:-$here/../Mettle/bin/mettle}"
L017="${METTLE_L017:-$HOME/.mbuild/toolchains/v0.17.0/linux/bin/mettle}"
W017="${METTLE_W017:-$HOME/.mbuild/toolchains/v0.17.0/windows/mettle.exe}"
HEAD_RT="$(dirname "$HEAD")/runtime"
W017_RT="$(dirname "$W017")/runtime"
export WINEDEBUG=-all

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/    | /' "$2" | head -40; }
check() { # name, command...
  name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
has() { grep -q -- "$2" "$1"; }   # file, pattern
hasnt() { ! grep -q -- "$2" "$1"; }

rm -rf "$W"
mkdir -p "$W"
"$here/tests/fixtures/make-fixtures.sh" "$W/fx" >/dev/null || { echo "fixtures failed"; exit 1; }
APP="$W/fx/app"
G="$W/fx/gitbase/github.com/demo"

# --- materialise the dependencies by hand -------------------------------------
D="$APP/.mbuild/deps/github.com/demo"
mkdir -p "$D"
git clone -q "$G/vecmath" "$D/vecmath" && git -C "$D/vecmath" checkout -q v0.1.0
git clone -q "$G/strutil" "$D/strutil" && git -C "$D/strutil" checkout -q v1.0.0
git clone -q "$G/nomanifest" "$D/nomanifest"
echo "github.com=./.mbuild/deps/github.com" > "$APP/mettle.deps"

# A second C file in vecmath that does not include vec.h, so a header edit
# must recompile exactly one object.
cat > "$D/vecmath/csrc/extra.c" <<'EOF'
int vm_extra(int x) { return x + 1; }
EOF

# A vendored library under [link] paths, and a pkg-config package.
mkdir -p "$APP/vendor/lib" "$APP/vendor/src"
cat > "$APP/vendor/src/vend.c" <<'EOF'
int vend_answer(void) { return 42; }
EOF
gcc -shared -fPIC -o "$APP/vendor/lib/libvend.so.1" -Wl,-soname,libvend.so.1 "$APP/vendor/src/vend.c"
ln -sf libvend.so.1 "$APP/vendor/lib/libvend.so"
x86_64-w64-mingw32-gcc -shared -static-libgcc -o "$APP/vendor/lib/vend.dll" "$APP/vendor/src/vend.c"
cat >> "$APP/mbuild.toml" <<'EOF'

[link]
libs = ["vend"]
paths = ["vendor/lib"]

[link.linux]
pkgconfig = ["zlib"]
EOF
cat > "$APP/src/vend.mettle" <<'EOF'
export extern fn vend_answer() -> int32 = "vend_answer";
EOF
# A runtime name, and a Win32 name only imported for windows.
cat > "$APP/src/rt.mettle" <<'EOF'
export extern fn rt_strlen(s: cstring) -> int64 = "strlen";
EOF
cat > "$APP/src/plat_win.mettle" <<'EOF'
export extern fn pw_ticks() -> uint64 = "GetTickCount64";
EOF
sed -i 's|^import "github.com/demo/nomanifest/greet";|import "github.com/demo/nomanifest/greet";\nimport "vend";\nimport "rt";\nimport "plat_win" if windows;|; s|println(greet("mbuild"));|println(greet("mbuild"));\n  println("vend={vend_answer()}");|' "$APP/src/main.mettle"

# --- the driver ---------------------------------------------------------------
DRV="$W/native_driver"
"$HEAD" --build "$here/tests/native_driver.mettle" -o "$DRV" >"$W/drv.log" 2>&1 || { bad "build driver" "$W/drv.log"; exit 1; }
if grep -q "warning" "$W/drv.log"; then bad "driver builds without warnings" "$W/drv.log"; else ok "driver builds without warnings"; fi

# prepare TARGET OUTFILE: runs the driver, splits its output into args/env/copy.
prepare() {
  "$DRV" "$APP" "$1" prepare >"$2" 2>&1
  rc=$?
  cp "$2" "$2.err"
  return $rc
}
args_of() { sed -n 's/^arg //p' "$1"; }
copies_of() { sed -n 's/^copy //p' "$1"; }

# --- linux --------------------------------------------------------------------
export MB_RUNTIME_DIR="$HEAD_RT"
prepare linux "$W/p1" && ok "prepare linux" || bad "prepare linux" "$W/p1.err"
sed 's/^/    /' "$W/p1"
check "compiled vecmath (2 C files)" has "$W/p1.err" "Compiling vecmath (C, 2 files)"
check "linux args name the C library" has "$W/p1" "^arg -lmb_vecmath$"
check "linux args carry [link] libs" has "$W/p1" "^arg -lvend$"
check "linux args carry pkg-config libs" has "$W/p1" "^arg -lz$"
check "linux args carry --rpath \$ORIGIN" has "$W/p1" '^arg \$ORIGIN$'
check "copy list has the C library" has "$W/p1" "^copy .*/libmb_vecmath.so$"
check "copy list has the vendored library" has "$W/p1" "^copy .*/vendor/lib/libvend.so.1$"
OUT="$APP/build/linux/debug"
mkdir -p "$OUT"
( cd "$APP" && "$HEAD" --build src/main.mettle -o build/linux/debug/app $(args_of "$W/p1") ) >"$W/c1.log" 2>&1 \
  && ok "head compiles the app with the native args" || bad "head compiles the app with the native args" "$W/c1.log"
for f in $(copies_of "$W/p1"); do cp "$f" "$OUT/"; done
"$OUT/app" >"$W/run1.log" 2>&1
check "linux app runs (dot=50.0 len=5.0)" has "$W/run1.log" "dot=50.0 len=5.0"
check "linux app calls the vendored library" has "$W/run1.log" "vend=42"
( cd "$APP" && "$L017" --build src/main.mettle -o build/linux/debug/app017 $(args_of "$W/p1") ) >"$W/c1b.log" 2>&1 \
  && "$OUT/app017" | grep -q "dot=50.0 len=5.0" && ok "v0.17.0 linux builds and runs it too" || bad "v0.17.0 linux builds and runs it too" "$W/c1b.log"

prepare linux "$W/p2"
check "second prepare compiles nothing" hasnt "$W/p2.err" "Compiling"
check "second prepare: same fingerprint" [ "$(grep '^fp' "$W/p1")" = "$(grep '^fp' "$W/p2")" ]

OBJ="$APP/.mbuild/cache/linux/c/vecmath/csrc"
before_extra=$(stat -c %y "$OBJ/extra.c.o")
sleep 1
touch "$D/vecmath/csrc/include/vec.h"
prepare linux "$W/p3"
check "touching vec.h (same content) compiles nothing" hasnt "$W/p3.err" "Compiling"
echo "/* edited */" >> "$D/vecmath/csrc/include/vec.h"
prepare linux "$W/p4"
check "editing vec.h recompiles exactly one file" has "$W/p4.err" "Compiling vecmath (C, 1 file)"
check "extra.c.o (no vec.h) untouched" [ "$before_extra" = "$(stat -c %y "$OBJ/extra.c.o")" ]
sed -i 's/cflags = \["-O2"\]/cflags = ["-O1"]/' "$D/vecmath/mbuild.toml"
prepare linux "$W/p5"
check "a cflags change recompiles both files" has "$W/p5.err" "Compiling vecmath (C, 2 files)"
check "fingerprint changed with the library" [ "$(grep '^fp' "$W/p4")" != "$(grep '^fp' "$W/p5")" ]

# A broken C file: the compiler's log is shown and prepare fails.
cp "$D/vecmath/csrc/extra.c" "$W/extra.c.bak"
echo "this is not C" >> "$D/vecmath/csrc/extra.c"
prepare linux "$W/p6" && bad "broken C fails prepare" || ok "broken C fails prepare"
check "broken C: compiler log shown" has "$W/p6.err" "extra.c"
check "broken C: error names the package" has "$W/p6.err" "could not compile the C code of github.com/demo/vecmath"
cp "$W/extra.c.bak" "$D/vecmath/csrc/extra.c"

# --- doctor (linux), all resolved ----------------------------------------------
"$DRV" "$APP" linux doctor >"$W/d1" 2>&1; rc=$?
cat "$W/d1" | sed 's/^/    /'
check "doctor linux: exit 0 when everything resolves" [ $rc = 0 ]
check "doctor lists vm_dot in the C library" has "$W/d1" "vm_dot.*C library libmb_vecmath.so"
check "doctor lists vend_answer in [link]" has "$W/d1" "vend_answer.*\[link\] library libvend.so"
check "doctor: strlen in the Mettle runtime" has "$W/d1" "strlen .*Mettle runtime"
check "doctor linux skips the windows-only import" hasnt "$W/d1" "GetTickCount64"
check "doctor linux counts 5 externs" has "$W/d1" "linux: 5 externs"

# --- windows (mingw, from Linux) -----------------------------------------------
export MB_RUNTIME_DIR="$W017_RT"
prepare windows "$W/w1" && ok "prepare windows" || bad "prepare windows" "$W/w1.err"
sed 's/^/    /' "$W/w1"
check "windows args: --link-arg -lmb_vecmath" has "$W/w1" "^arg -lmb_vecmath$"
check "windows args: --link-arg" has "$W/w1" "^arg --link-arg$"
check "windows env: WINEPATH with Z: dirs" has "$W/w1" '^env WINEPATH=Z:\\'
check "windows copies the DLL" has "$W/w1" "^copy .*/mb_vecmath.dll$"
check "windows copies the vendored DLL" has "$W/w1" "^copy .*/vendor/lib/vend.dll$"
check "windows: no -l from pkg-config" hasnt "$W/w1" "^arg -lz$"
WOUT="$APP/build/windows/debug"
mkdir -p "$WOUT"
WENV=$(sed -n 's/^env //p' "$W/w1")
( cd "$APP" && env "$WENV" wine "$W017" --build src/main.mettle -o build/windows/debug/app.exe $(args_of "$W/w1") ) >"$W/wc1.log" 2>&1 \
  && ok "wine mettle.exe compiles the app" || bad "wine mettle.exe compiles the app" "$W/wc1.log"
for f in $(copies_of "$W/w1"); do cp "$f" "$WOUT/"; done
( cd "$WOUT" && wine app.exe ) >"$W/wrun1.log" 2>&1
check "windows app runs under wine" has "$W/wrun1.log" "dot=50.0 len=5.0"
check "windows app calls the vendored DLL" has "$W/wrun1.log" "vend=42"
prepare windows "$W/w2"
check "windows second prepare compiles nothing" hasnt "$W/w2.err" "Compiling"

"$DRV" "$APP" windows doctor >"$W/wd1" 2>&1; rc=$?
cat "$W/wd1" | sed 's/^/    /'
check "doctor windows: exit 0" [ $rc = 0 ]
check "doctor windows: vm_len in the DLL" has "$W/wd1" "vm_len.*C library mb_vecmath.dll"
check "doctor windows: GetTickCount64 in kernel32" has "$W/wd1" "GetTickCount64 .*Windows default DLL kernel32.dll"
check "doctor windows: strlen in the runtime" has "$W/wd1" "strlen .*Mettle runtime"

# --- the driver as a Windows program under wine ----------------------------------
"$W017" >/dev/null 2>&1 || true
wine "$W017" --build "$here/tests/native_driver.mettle" -o "$W/native_driver.exe" >"$W/wdrv.log" 2>&1 \
  && ok "driver builds as a Windows exe" || bad "driver builds as a Windows exe" "$W/wdrv.log"
rm -rf "$APP/.mbuild/cache/windows"
MB_RUNTIME_DIR="Z:$W017_RT" wine "$W/native_driver.exe" "Z:$APP" windows prepare >"$W/ww1" 2>&1 \
  && ok "wine driver: prepare windows" || bad "wine driver: prepare windows" "$W/ww1.err"
tr -d '\r' <"$W/ww1" >"$W/ww1.u"
sed 's/^/    /' "$W/ww1.u"
check "wine driver compiled with host mingw" has "$W/ww1.u" "Compiling vecmath (C, 2 files)"
check "wine driver: DLL built" [ -f "$APP/.mbuild/cache/windows/lib/mb_vecmath.dll" ]
check "wine driver: env PATH" has "$W/ww1.u" "^env PATH=Z:"
MB_RUNTIME_DIR="Z:$W017_RT" wine "$W/native_driver.exe" "Z:$APP" windows prepare >"$W/ww2" 2>&1
check "wine driver: second prepare compiles nothing" hasnt "$W/ww2" "Compiling"
# The wine driver's DLL links and runs too.
rm -f "$WOUT/app.exe"
( cd "$APP" && env "$WENV" wine "$W017" --build src/main.mettle -o build/windows/debug/app.exe $(args_of "$W/w1") ) >"$W/wc2.log" 2>&1
cp "$APP/.mbuild/cache/windows/lib/mb_vecmath.dll" "$WOUT/"
( cd "$WOUT" && wine app.exe ) 2>&1 | grep -q "dot=50.0 len=5.0" && ok "wine-built DLL runs" || bad "wine-built DLL runs" "$W/wc2.log"
MB_RUNTIME_DIR="Z:$W017_RT" wine "$W/native_driver.exe" "Z:$APP" linux prepare >"$W/wl1" 2>"$W/wl1.err" \
  && ok "wine driver: prepare linux (host gcc)" || bad "wine driver: prepare linux (host gcc)" "$W/wl1.err"
tr -d '\r' <"$W/wl1" | grep -q "^arg -L/" && ok "wine driver: linux -L in host form" || bad "wine driver: linux -L in host form" "$W/wl1"
MB_RUNTIME_DIR="Z:$W017_RT" wine "$W/native_driver.exe" "Z:$APP" windows doctor 2>&1 | tr -d '\r' >"$W/wwd"
check "wine driver: doctor finds GetTickCount64 in kernel32" has "$W/wwd" "GetTickCount64 .*Windows default DLL kernel32.dll"
check "wine driver: doctor reads the C library" has "$W/wwd" "vm_dot .*C library mb_vecmath.dll"
MB_RUNTIME_DIR="Z:$HEAD_RT" wine "$W/native_driver.exe" "Z:$APP" linux doctor 2>&1 | tr -d '\r' >"$W/wld"
check "wine driver: linux doctor reads ELF through Z:" has "$W/wld" "strlen .*Mettle runtime"

# --- unresolved symbols --------------------------------------------------------
sed -i 's|^fn main() -> int32 {|extern fn vm_missing(x: int32) -> int32 = "vm_missing";\nextern fn cos(x: float64) -> float64 = "cos";\n\nfn main() -> int32 {\n  println("{vm_missing(1)} {cos(0.5)}");|' "$APP/src/main.mettle"
MISSLINE=$(grep -n 'extern fn vm_missing' "$APP/src/main.mettle" | cut -d: -f1)
COSLINE=$(grep -n 'extern fn cos' "$APP/src/main.mettle" | cut -d: -f1)
export MB_RUNTIME_DIR="$HEAD_RT"
prepare linux "$W/p7"
( cd "$APP" && "$HEAD" --build src/main.mettle -o build/linux/debug/app $(args_of "$W/p7") ) >"$W/fail-head.log" 2>&1 \
  && bad "head link fails on vm_missing" || ok "head link fails on vm_missing"
( cd "$APP" && "$L017" --build src/main.mettle -o build/linux/debug/app $(args_of "$W/p7") ) >"$W/fail-l017.log" 2>&1
( cd "$APP" && "$L017" --build src/main.mettle -o build/linux/debug/app ) >"$W/fail-l017-ld.log" 2>&1
for v in head l017 l017-ld; do
  "$DRV" "$APP" linux explain "$W/fail-$v.log" >"$W/ex-$v" 2>&1
  echo "  --- explain ($v):"; sed 's/^/    /' "$W/ex-$v"
  check "explain $v names vm_missing's extern" has "$W/ex-$v" "src/main.mettle:$MISSLINE"
  check "explain $v names cos's extern" has "$W/ex-$v" "src/main.mettle:$COSLINE"
  check "explain $v suggests libm for cos" has "$W/ex-$v" 'libs = \["m"\]'
  check "explain $v notes std/math" has "$W/ex-$v" "std/math"
done
check "explain (ld output) takes every name ld lists" hasnt "$W/ex-l017-ld" "^also"

export MB_RUNTIME_DIR="$W017_RT"
( cd "$APP" && env "$WENV" wine "$W017" --build src/main.mettle -o build/windows/debug/app.exe $(args_of "$W/w1") ) >"$W/fail-w017.log" 2>&1
"$DRV" "$APP" windows explain "$W/fail-w017.log" >"$W/ex-w017" 2>&1
echo "  --- explain (w017):"; sed 's/^/    /' "$W/ex-w017"
check "explain w017 names vm_missing's extern" has "$W/ex-w017" "src/main.mettle:$MISSLINE"
check "explain w017: cos only in a C runtime DLL" has "$W/ex-w017" "C runtime DLL"

export MB_RUNTIME_DIR="$HEAD_RT"
"$DRV" "$APP" linux doctor >"$W/d2" 2>&1; rc=$?
sed 's/^/    /' "$W/d2"
check "doctor: non-zero with unresolved externs" [ $rc != 0 ]
check "doctor: vm_missing UNRESOLVED" has "$W/d2" "vm_missing .*UNRESOLVED"
check "doctor: cos UNRESOLVED" has "$W/d2" "cos .*UNRESOLVED"
check "doctor lists every extern for linux (7)" has "$W/d2" "linux: 7 externs"

# --- pkg-config failures -----------------------------------------------------------
sed -i 's/pkgconfig = \["zlib"\]/pkgconfig = ["no-such-package-xyz"]/' "$APP/mbuild.toml"
prepare linux "$W/p8" && bad "unknown pkg-config package fails" || ok "unknown pkg-config package fails"
check "pkg-config failure has a hint" has "$W/p8.err" "pkg-config does not know 'no-such-package-xyz'"

# --- symbols on garbage ---------------------------------------------------------------
head -c 5000 /dev/urandom >"$W/garbage.so"
printf 'MZ\001\002' >"$W/short.dll"
head -c 300 /lib/x86_64-linux-gnu/libc.so.6 >"$W/trunc.so"
for f in garbage.so short.dll trunc.so; do
  "$DRV" "$APP" linux syms "$W/$f" >/dev/null 2>&1 && ok "symbols survive $f" || bad "symbols survive $f"
done
"$DRV" "$APP" linux syms /lib/x86_64-linux-gnu/libm.so.6 | grep -qx cos && ok "symbols: libm.so.6 defines cos" || bad "symbols: libm.so.6 defines cos"
"$DRV" "$APP" linux syms "$W017_RT/freestanding.obj" | grep -qx malloc && ok "symbols: COFF runtime defines malloc" || bad "symbols: COFF runtime defines malloc"

"$DRV" x linux soname /lib/x86_64-linux-gnu/libm.so.6 | grep -qx "soname libm.so.6" && ok "symbols: soname of libm.so.6" || bad "symbols: soname of libm.so.6"

# --- C calling C across packages ---------------------------------------------------
# capi's C defines a_val (and a header under [c] include); cuser's C includes
# that header and calls a_val; the app calls cuser's u_val.
C="$W/chain/app"
CD="$C/.mbuild/deps/github.com/demo"
mkdir -p "$C/src" "$CD/capi/csrc" "$CD/capi/include" "$CD/cuser/csrc"
cat > "$C/mbuild.toml" <<'EOF'
[package]
name = "app"

[dependencies]
"github.com/demo/cuser" = "v0.1.0"

[profile.release]
cflags = ["-DCAPI_EXTRA=100"]
EOF
echo "github.com=./.mbuild/deps/github.com" > "$C/mettle.deps"
cat > "$C/src/main.mettle" <<'EOF'
import "std/io";
import "github.com/demo/cuser/cuser";

fn main() -> int32 {
  println("u={u_val()}");
  return 0;
}
EOF
cat > "$CD/capi/mbuild.toml" <<'EOF'
[package]
name = "capi"
module = "github.com/demo/capi"

[c]
sources = ["csrc"]
include = ["include"]
EOF
cat > "$CD/capi/include/capi.h" <<'EOF'
#define CAPI_BASE 40
int a_val(void);
EOF
cat > "$CD/capi/csrc/a.c" <<'EOF'
#include "capi.h"
#ifndef CAPI_EXTRA
#define CAPI_EXTRA 0
#endif
int a_val(void) { return CAPI_BASE + CAPI_EXTRA; }
EOF
echo 'export extern fn a_val() -> int32 = "a_val";' > "$CD/capi/capi.mettle"
cat > "$CD/cuser/mbuild.toml" <<'EOF'
[package]
name = "cuser"
module = "github.com/demo/cuser"

[dependencies]
"github.com/demo/capi" = "v0.1.0"

[c]
sources = ["csrc"]
EOF
cat > "$CD/cuser/csrc/u.c" <<'EOF'
#include "capi.h"
int u_val(void) { return a_val() + 2; }
EOF
echo 'export extern fn u_val() -> int32 = "u_val";' > "$CD/cuser/cuser.mettle"
# A nested project and a build/ directory: their externs are not the app's.
mkdir -p "$C/examples/nested/src" "$C/build/gen"
printf '[package]\nname = "nested"\n' > "$C/examples/nested/mbuild.toml"
echo 'extern fn nested_only_sym() -> int32 = "nested_only_sym";' > "$C/examples/nested/src/main.mettle"
echo 'extern fn build_only_sym() -> int32 = "build_only_sym";' > "$C/build/gen/x.mettle"

export MB_RUNTIME_DIR="$HEAD_RT"
"$DRV" "$C" linux prepare >"$W/cc1" 2>&1 && ok "chain: prepare linux" || bad "chain: prepare linux" "$W/cc1"
sed 's/^/    /' "$W/cc1"
check "chain: capi's C is built before cuser's" [ "$(grep -n 'Compiling capi' "$W/cc1" | cut -d: -f1)" -lt "$(grep -n 'Compiling cuser' "$W/cc1" | cut -d: -f1)" ]
check "chain: app link order puts cuser before capi" [ "$(grep -n '^arg -lmb_cuser$' "$W/cc1" | cut -d: -f1)" -lt "$(grep -n '^arg -lmb_capi$' "$W/cc1" | cut -d: -f1)" ]
check "chain: libmb_cuser.so needs libmb_capi.so" sh -c "readelf -d '$C/.mbuild/cache/linux/lib/libmb_cuser.so' | grep -q 'NEEDED.*libmb_capi.so'"
check "chain: libmb_cuser.so has rpath \$ORIGIN" sh -c "readelf -d '$C/.mbuild/cache/linux/lib/libmb_cuser.so' | grep -q 'PATH.*\\\$ORIGIN'"
mkdir -p "$C/build/linux/debug"
( cd "$C" && "$HEAD" --build src/main.mettle -o build/linux/debug/app $(args_of "$W/cc1") ) >"$W/ccb1.log" 2>&1 \
  && ok "chain: head links the app" || bad "chain: head links the app" "$W/ccb1.log"
for f in $(copies_of "$W/cc1"); do cp "$f" "$C/build/linux/debug/"; done
"$C/build/linux/debug/app" >"$W/ccr1.log" 2>&1
check "chain: linux app runs C calling C (u=42)" has "$W/ccr1.log" "u=42"
"$DRV" "$C" linux doctor >"$W/ccd" 2>&1; rc=$?
sed 's/^/    /' "$W/ccd"
check "chain doctor: exit 0" [ $rc = 0 ]
check "chain doctor: u_val in libmb_cuser.so" has "$W/ccd" "u_val .*C library libmb_cuser.so"
check "chain doctor: skips the nested project" hasnt "$W/ccd" "nested_only_sym"
check "chain doctor: skips build/" hasnt "$W/ccd" "build_only_sym"
check "chain doctor: 2 externs" has "$W/ccd" "linux: 2 externs"

# The header in capi's [c] include changes: cuser's object (which includes
# it) recompiles too.
echo "/* edited */" >> "$CD/capi/include/capi.h"
"$DRV" "$C" linux prepare >"$W/cc2" 2>&1
check "chain: a dependency header edit recompiles the dependent" has "$W/cc2" "Compiling cuser (C, 1 file)"

# Profile C flags: [profile.release] cflags reach every package's C code,
# in their own cache directory, so debug stays fresh.
MB_PROFILE=release "$DRV" "$C" linux prepare >"$W/cc3" 2>&1 && ok "chain: prepare release" || bad "chain: prepare release" "$W/cc3"
check "chain release: copies from lib-release" has "$W/cc3" "^copy .*/lib-release/libmb_capi.so$"
mkdir -p "$C/build/linux/release"
( cd "$C" && "$HEAD" --build src/main.mettle -o build/linux/release/app $(args_of "$W/cc3") ) >"$W/ccb3.log" 2>&1
for f in $(copies_of "$W/cc3"); do cp "$f" "$C/build/linux/release/"; done
"$C/build/linux/release/app" >"$W/ccr3.log" 2>&1
check "chain release: profile cflags applied (u=142)" has "$W/ccr3.log" "u=142"
"$DRV" "$C" linux prepare >"$W/cc4" 2>&1
check "chain: debug still fresh after a release prepare" hasnt "$W/cc4" "Compiling"

# Windows: mingw links mb_cuser.dll against mb_capi.dll.
export MB_RUNTIME_DIR="$W017_RT"
"$DRV" "$C" windows prepare >"$W/cw1" 2>&1 && ok "chain: prepare windows" || bad "chain: prepare windows" "$W/cw1"
sed 's/^/    /' "$W/cw1"
mkdir -p "$C/build/windows/debug"
CWENV=$(sed -n 's/^env //p' "$W/cw1")
( cd "$C" && env "$CWENV" wine "$W017" --build src/main.mettle -o build/windows/debug/app.exe $(args_of "$W/cw1") ) >"$W/cwb1.log" 2>&1 \
  && ok "chain: wine mettle.exe links the app" || bad "chain: wine mettle.exe links the app" "$W/cwb1.log"
for f in $(copies_of "$W/cw1"); do cp "$f" "$C/build/windows/debug/"; done
( cd "$C/build/windows/debug" && wine app.exe ) >"$W/cwr1.log" 2>&1
check "chain: windows app runs C calling C (u=42)" has "$W/cwr1.log" "u=42"

# Linux mbuild and wine mbuild.exe alternating on one project rebuild nothing.
for tg in linux windows; do
  "$DRV" "$C" $tg prepare >/dev/null 2>&1
  wine "$W/native_driver.exe" "Z:$C" $tg prepare 2>&1 | tr -d '\r' >"$W/alt-$tg-w1"
  "$DRV" "$C" $tg prepare >"$W/alt-$tg-l2" 2>&1
  wine "$W/native_driver.exe" "Z:$C" $tg prepare 2>&1 | tr -d '\r' >"$W/alt-$tg-w2"
  check "alternating hosts ($tg): the wine driver ran" has "$W/alt-$tg-w2" "^fp "
  check "alternating hosts ($tg): wine after linux compiles nothing" hasnt "$W/alt-$tg-w1" "Compiling"
  check "alternating hosts ($tg): linux after wine compiles nothing" hasnt "$W/alt-$tg-l2" "Compiling"
  check "alternating hosts ($tg): wine again compiles nothing" hasnt "$W/alt-$tg-w2" "Compiling"
  check "alternating hosts ($tg): same fingerprint" [ "$(grep '^fp' "$W/alt-$tg-l2")" = "$(grep '^fp' "$W/alt-$tg-w2")" ]
done

# --- the report lists each library once ------------------------------------------------
Z="$W/zapp"
mkdir -p "$Z/src"
printf '[package]\nname = "zapp"\n\n[link.windows]\npkgconfig = ["foo"]\n' > "$Z/mbuild.toml"
cat > "$Z/src/main.mettle" <<'EOF'
import "std/io";
extern fn bound(n: int64) -> int64 = "compressBound";
fn main() -> int32 {
  println("{bound(100)}");
  return 0;
}
EOF
export MB_RUNTIME_DIR="$HEAD_RT"
"$DRV" "$Z" linux doctor >"$W/zd" 2>&1
sed 's/^/    /' "$W/zd"
check "report: libz listed once" [ "$(grep -c 'defined in .*libz\.so' "$W/zd")" = 1 ]
check "report: development name with the soname" has "$W/zd" 'defined in .*/libz\.so (libz\.so\.1)$'
check "report: suggests libs = [\"z\"]" has "$W/zd" 'libs = \["z"\]'

# --- pkg-config for the windows target ---------------------------------------------------
printf '#!/bin/sh\necho "-lfoo"\n' > "$W/fake-pc"
chmod +x "$W/fake-pc"
PKG_CONFIG_WINDOWS="$W/fake-pc" "$DRV" "$Z" windows prepare >"$W/zp1" 2>&1
check "PKG_CONFIG_WINDOWS: its -l reaches the windows link" has "$W/zp1" "^arg -lfoo$"
PKG_CONFIG_WINDOWS= PATH=/usr/bin:/bin "$DRV" "$Z" windows prepare >"$W/zp2" 2>&1
if command -v x86_64-w64-mingw32-pkg-config >/dev/null; then
  check "mingw pkg-config used for windows" hasnt "$W/zp2" "is ignored for the windows target"
else
  check "no windows pkg-config: warned and skipped" has "$W/zp2" "is ignored for the windows target"
fi
PKG_CONFIG_WINDOWS="$W/fake-pc" wine "$W/native_driver.exe" "Z:$Z" windows prepare 2>&1 | tr -d '\r' >"$W/zp3"
check "wine driver: PKG_CONFIG_WINDOWS as a host program" has "$W/zp3" "^arg -lfoo$"

echo
echo "native_test: $pass passed, $fail failed"
[ $fail = 0 ]
