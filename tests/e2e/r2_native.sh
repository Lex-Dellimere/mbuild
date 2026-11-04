#!/bin/sh
# r2_native.sh: round-2 native checks (DESIGN.md 12.14, 12.21 group N)
# through tests/native_driver.mettle, against the round-2 fixtures.
#
#   sh tests/r2_native.sh [WORKDIR]       (default /tmp/opencode/r2-native)
#
# - cdup1 + cdup2 both export dup_value: each library calls its own copy
#   (`1 2`), on Linux (-Wl,-Bsymbolic) and on Windows (PE, under wine);
# - the duplicate-export warning when an extern binds dup_value, and only
#   a -v note without one;
# - wrapper compiles its C from git submodule paths (42);
# - a [replace]d (linked) module builds from its real directory; a project
#   that imports itself builds its C once.
#
# Needs: gcc, x86_64-w64-mingw32-gcc, wine, the head compiler and the
# v0.17.0 toolchains under ~/.mbuild/toolchains.

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
W="${1:-/tmp/opencode/r2-native}"
HEAD="${METTLE_HEAD:-$here/../Mettle/bin/mettle}"
L017="${METTLE_L017:-$HOME/.mbuild/toolchains/v0.17.0/linux/bin/mettle}"
W017="${METTLE_W017:-$HOME/.mbuild/toolchains/v0.17.0/windows/mettle.exe}"
HEAD_RT="$(dirname "$HEAD")/runtime"
W017_RT="$(dirname "$W017")/runtime"
export WINEDEBUG=-all
unset MB_VERBOSE MB_PROFILE CC CC_WINDOWS

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

rm -rf "$W"
mkdir -p "$W"
"$here/tests/fixtures/make-fixtures.sh" "$W/fx" >/dev/null || { echo "fixtures failed"; exit 1; }
R2="$here/tests/fixtures/make-fixtures-r2.sh"
[ -f "$R2" ] || R2="$here/tests/fixtures/make-round2.sh"
sh "$R2" "$W/fx" >/dev/null || { echo "round-2 fixtures failed"; exit 1; }
G="$W/fx/gitbase/github.com/demo"

# --- drivers ---------------------------------------------------------------------
DRV="$W/native_driver"
"$HEAD" --build "$here/tests/unit/native_driver.mettle" -o "$DRV" >"$W/drv.log" 2>&1 || { bad "build driver" "$W/drv.log"; exit 1; }
if grep -q "warning" "$W/drv.log"; then bad "driver builds without warnings" "$W/drv.log"; else ok "driver builds without warnings"; fi
"$W017" >/dev/null 2>&1 || true
wine "$W017" --build "$here/tests/unit/native_driver.mettle" -o "$W/native_driver.exe" >"$W/wdrv.log" 2>&1 \
  && ok "driver builds as a Windows exe" || bad "driver builds as a Windows exe" "$W/wdrv.log"

# new_app DIR: a project skeleton requiring the modules given after DIR.
new_app() {
  d="$1"; shift
  mkdir -p "$d/src" "$d/.mbuild/deps/github.com/demo"
  { printf '[package]\nname = "app"\n\n[dependencies]\n'
    for m in "$@"; do printf '"github.com/demo/%s" = "v1.0.0"\n' "$m"; done; } > "$d/mbuild.toml"
  echo "github.com=./.mbuild/deps/github.com" > "$d/mettle.deps"
}
dep_clone() { # app module tag
  git -c protocol.file.allow=always clone -q "$G/$2" "$1/.mbuild/deps/github.com/demo/$2"
  git -C "$1/.mbuild/deps/github.com/demo/$2" -c advice.detachedHead=false checkout -q "$3"
  git -C "$1/.mbuild/deps/github.com/demo/$2" -c protocol.file.allow=always submodule -q update --init --recursive
}
# build_run APP TARGET PREPFILE LABEL: links src/main.mettle with the prepared
# arguments (head for linux, v0.17.0 under wine for windows), copies the
# libraries beside it and runs it into PREPFILE.run.
build_run() {
  a="$1"; tg="$2"; pf="$3"
  if [ "$tg" = linux ]; then
    mkdir -p "$a/build/linux/debug"
    ( cd "$a" && "$HEAD" --build src/main.mettle -o build/linux/debug/app $(args_of "$pf") ) >"$pf.cc" 2>&1 || return 1
    for f in $(copies_of "$pf"); do cp "$f" "$a/build/linux/debug/"; done
    "$a/build/linux/debug/app" >"$pf.run" 2>&1
  else
    mkdir -p "$a/build/windows/debug"
    wenv=$(sed -n 's/^env //p' "$pf")
    ( cd "$a" && env "$wenv" wine "$W017" --build src/main.mettle -o build/windows/debug/app.exe $(args_of "$pf") ) >"$pf.cc" 2>&1 || return 1
    for f in $(copies_of "$pf"); do cp "$f" "$a/build/windows/debug/"; done
    ( cd "$a/build/windows/debug" && wine app.exe ) 2>&1 | tr -d '\r' >"$pf.run"
  fi
}

# --- cdup: one C symbol in two packages -------------------------------------------
A="$W/cdup"
new_app "$A" cdup1 cdup2
dep_clone "$A" cdup1 v1.0.0
dep_clone "$A" cdup2 v1.0.0
cat > "$A/src/main.mettle" <<'EOF'
import "std/io";
import "github.com/demo/cdup1/cdup1";
import "github.com/demo/cdup2/cdup2";

fn main() -> int32 {
  println("{cdup1_only()} {cdup2_only()}");
  return 0;
}
EOF

# The interposition the fix is about, reproduced without mbuild: plain
# shared libraries linked -lcdup1 -lcdup2 make cdup2's C call cdup1's copy.
X="$W/control"
mkdir -p "$X"
for n in 1 2; do
  gcc -shared -fPIC -o "$X/libmb_cdup$n.so" -Wl,-soname,libmb_cdup$n.so "$G/cdup$n/dup.c"
done
( cd "$A" && "$HEAD" --build src/main.mettle -o "$X/app" -L"$X" -lmb_cdup1 -lmb_cdup2 --rpath '$ORIGIN' ) >"$X/cc.log" 2>&1
"$X/app" >"$X/run" 2>&1
check "control: without -Bsymbolic cdup2's C calls cdup1's dup_value (1 1)" [ "$(cat "$X/run")" = "1 1" ]

export MB_RUNTIME_DIR="$HEAD_RT"
"$DRV" "$A" linux prepare >"$W/c1" 2>&1 && ok "cdup: prepare linux" || bad "cdup: prepare linux" "$W/c1"
check "cdup: both C libraries built" [ -f "$A/.mbuild/cache/linux/lib/libmb_cdup1.so" -a -f "$A/.mbuild/cache/linux/lib/libmb_cdup2.so" ]
check "cdup: libraries are linked -Bsymbolic" sh -c "readelf -d '$A/.mbuild/cache/linux/lib/libmb_cdup2.so' | grep -q 'SYMBOLIC'"
check "cdup: no warning without an extern binding dup_value" hasnt "$W/c1" "warning"
check "cdup: dupsyms cached" has "$A/.mbuild/cache/linux/dupsyms" "^dup_value	"
build_run "$A" linux "$W/c1" && ok "cdup: head links the app" || bad "cdup: head links the app" "$W/c1.cc"
check "cdup linux: each library calls its own dup_value (1 2)" [ "$(cat "$W/c1.run")" = "1 2" ]
( cd "$A" && "$L017" --build src/main.mettle -o build/linux/debug/app017 $(args_of "$W/c1") ) >"$W/c1.l017" 2>&1
check "cdup linux, v0.17.0: 1 2" [ "$("$A/build/linux/debug/app017" 2>&1)" = "1 2" ]
MB_VERBOSE=1 "$DRV" "$A" linux prepare >"$W/c2" 2>&1
check "cdup: second prepare compiles nothing" hasnt "$W/c2" "Compiling"
check "cdup -v: note names both packages" hasf "$W/c2" "the C function dup_value is defined by both github.com/demo/cdup1 (libmb_cdup1.so) and github.com/demo/cdup2 (libmb_cdup2.so); no extern binds it"
check "cdup -v: still no warning" hasnt "$W/c2" "warning"
# An extern of dup_value in a file nothing imports binds nothing.
echo 'export extern fn stray_dup() -> int32 = "dup_value";' > "$A/.mbuild/deps/github.com/demo/cdup2/unused.mettle"
"$DRV" "$A" linux prepare >"$W/c2b" 2>&1
check "cdup: an extern in a file nothing imports does not warn" hasnt "$W/c2b" "warning"
rm -f "$A/.mbuild/deps/github.com/demo/cdup2/unused.mettle"

export MB_RUNTIME_DIR="$W017_RT"
"$DRV" "$A" windows prepare >"$W/cw1" 2>&1 && ok "cdup: prepare windows" || bad "cdup: prepare windows" "$W/cw1"
check "cdup windows: no warning" hasnt "$W/cw1" "warning"
build_run "$A" windows "$W/cw1" && ok "cdup: wine mettle.exe links the app" || bad "cdup: wine mettle.exe links the app" "$W/cw1.cc"
check "cdup windows (wine): each DLL calls its own dup_value (1 2)" [ "$(cat "$W/cw1.run")" = "1 2" ]
check "cdup windows: DLLs export dup_value (both)" sh -c "'$DRV' x windows syms '$A/.mbuild/cache/windows/lib/mb_cdup2.dll' | grep -qx dup_value"

# --- N-2: an extern binds the duplicated name ------------------------------------------
cat > "$A/src/main.mettle" <<'EOF'
import "std/io";
import "github.com/demo/cdup1/cdup1";
import "github.com/demo/cdup2/cdup2";

extern fn dup_value() -> int32 = "dup_value";

fn main() -> int32 {
  println("{cdup1_only()} {cdup2_only()} {dup_value()}");
  return 0;
}
EOF
LINE=$(grep -n 'extern fn dup_value' "$A/src/main.mettle" | cut -d: -f1)
export MB_RUNTIME_DIR="$HEAD_RT"
"$DRV" "$A" linux prepare >"$W/d1" 2>&1
sed 's/^/    /' "$W/d1" | grep -v '^    arg\|^    copy\|^    fp'
check "dup warning (linux): exact text" hasf "$W/d1" "warning: the C function dup_value is defined by both github.com/demo/cdup1 (libmb_cdup1.so) and github.com/demo/cdup2 (libmb_cdup2.so); the extern at src/main.mettle:$LINE binds to github.com/demo/cdup1's"
check "dup warning (linux): help" hasf "$W/d1" "  help: two packages build the same C code; depend on one package that wraps the library, or make the symbol static/hidden in one of them"
check "dup warning: from the cache too (nothing rebuilt)" hasnt "$W/d1" "Compiling"
build_run "$A" linux "$W/d1"
check "linux: the extern binds the first library linked (1 2 1)" [ "$(cat "$W/d1.run")" = "1 2 1" ]
export MB_RUNTIME_DIR="$W017_RT"
"$DRV" "$A" windows prepare >"$W/dw1" 2>&1
check "dup warning (windows): names the DLLs" hasf "$W/dw1" "warning: the C function dup_value is defined by both github.com/demo/cdup1 (mb_cdup1.dll) and github.com/demo/cdup2 (mb_cdup2.dll); the extern at src/main.mettle:$LINE binds to github.com/demo/cdup1's"
build_run "$A" windows "$W/dw1"
echo "    windows run with the dup_value extern: $(cat "$W/dw1.run")"
check "windows: the extern binds the first DLL linked (1 2 1)" [ "$(cat "$W/dw1.run")" = "1 2 1" ]
rm -rf "$A/.mbuild/cache/windows"
MB_RUNTIME_DIR="Z:$W017_RT" wine "$W/native_driver.exe" "Z:$A" windows prepare 2>&1 | tr -d '\r' >"$W/dw2"
check "wine driver: the same warning" hasf "$W/dw2" "warning: the C function dup_value is defined by both github.com/demo/cdup1 (mb_cdup1.dll) and github.com/demo/cdup2 (mb_cdup2.dll); the extern at src/main.mettle:$LINE binds to github.com/demo/cdup1's"

# --- wrapper: C from git submodule paths ------------------------------------------------
B="$W/wrap"
new_app "$B" wrapper
dep_clone "$B" wrapper v1.0.0
cat > "$B/src/main.mettle" <<'EOF'
import "std/io";
import "github.com/demo/wrapper/wrapper";

fn main() -> int32 {
  println("{clib_value()}");
  return 0;
}
EOF
export MB_RUNTIME_DIR="$HEAD_RT"
"$DRV" "$B" linux prepare >"$W/w1" 2>&1 && ok "wrapper: prepare linux" || bad "wrapper: prepare linux" "$W/w1"
check "wrapper: object from the submodule path" [ -f "$B/.mbuild/cache/linux/c/wrapper/vendor/clib/clib.c.o" ]
build_run "$B" linux "$W/w1"
check "wrapper linux: clib_value() = 42" [ "$(cat "$W/w1.run")" = "42" ]
export MB_RUNTIME_DIR="$W017_RT"
"$DRV" "$B" windows prepare >"$W/ww1" 2>&1 && ok "wrapper: prepare windows" || bad "wrapper: prepare windows" "$W/ww1"
build_run "$B" windows "$W/ww1"
check "wrapper windows (wine): clib_value() = 42" [ "$(cat "$W/ww1.run")" = "42" ]
# Moving the submodule to clib v1.1.0 (as wrapper v1.1.0 does) recompiles.
git -C "$B/.mbuild/deps/github.com/demo/wrapper" -c advice.detachedHead=false checkout -q v1.1.0
git -C "$B/.mbuild/deps/github.com/demo/wrapper" -c protocol.file.allow=always submodule -q update --init --recursive
export MB_RUNTIME_DIR="$HEAD_RT"
"$DRV" "$B" linux prepare >"$W/w2" 2>&1
check "wrapper: a new submodule commit recompiles" has "$W/w2" "Compiling wrapper (C, 1 file)"
build_run "$B" linux "$W/w2"
check "wrapper linux at v1.1.0: 43" [ "$(cat "$W/w2.run")" = "43" ]

# --- a [replace] path: the module directory is a link --------------------------------------
L="$W/cdup2-local"
git clone -q "$G/cdup2" "$L"
sed -i 's/return 2;/return 5;/' "$L/dup.c"
C="$W/repl"
new_app "$C" cdup1 cdup2
dep_clone "$C" cdup1 v1.0.0
ln -s "$L" "$C/.mbuild/deps/github.com/demo/cdup2"
cp "$A/src/main.mettle" "$C/src/main.mettle"
sed -i 's/ {dup_value()}//; /extern fn dup_value/d' "$C/src/main.mettle"
export MB_RUNTIME_DIR="$HEAD_RT"
"$DRV" "$C" linux prepare >"$W/r1" 2>&1 && ok "replace: prepare linux" || bad "replace: prepare linux" "$W/r1"
build_run "$C" linux "$W/r1"
check "replace: the local copy's C is used (1 5)" [ "$(cat "$W/r1.run")" = "1 5" ]
"$DRV" "$C" linux doctor >"$W/r2" 2>&1
check "replace: externs located in the real directory" hasf "$W/r2" "$L/cdup2.mettle:1"
check "replace: never through the link path" hasnt "$W/r2" ".mbuild/deps/github.com/demo/cdup2"
check "replace: depfile names the real source" has "$C/.mbuild/cache/linux/c/cdup2/dup.c.o.d" "$L/dup.c"
"$DRV" "$C" linux prepare >"$W/r3" 2>&1
check "replace: second prepare compiles nothing" hasnt "$W/r3" "Compiling"
sed -i 's/return 5;/return 6;/' "$L/dup.c"
"$DRV" "$C" linux prepare >"$W/r4" 2>&1
check "replace: an edit in the real directory recompiles" has "$W/r4" "Compiling cdup2 (C, 1 file)"
MB_RUNTIME_DIR="Z:$W017_RT" wine "$W/native_driver.exe" "Z:$C" windows doctor 2>&1 | tr -d '\r' >"$W/r5"
check "replace under wine: the link is resolved (host readlink)" has "$W/r5" "cdup2-local/cdup2.mettle:1"
check "replace under wine: C built from the real directory" has "$C/.mbuild/cache/windows/c/cdup2/dup.c.o.d" "cdup2-local/dup.c"

# --- importing yourself: the root linked under its own module path ------------------------
S="$W/selfy"
mkdir -p "$S/csrc" "$S/cmd/demo" "$S/.mbuild/deps/github.com/me"
printf '[package]\nname = "selfy"\nmodule = "github.com/me/selfy"\n\n[c]\nsources = ["csrc"]\n' > "$S/mbuild.toml"
echo 'int selfy_val(void) { return 7; }' > "$S/csrc/s.c"
echo 'export extern fn selfy_val() -> int32 = "selfy_val";' > "$S/lib.mettle"
cat > "$S/cmd/demo/main.mettle" <<'EOF'
import "std/io";
import "github.com/me/selfy/lib";

fn main() -> int32 {
  println("selfy={selfy_val()}");
  return 0;
}
EOF
echo "github.com=./.mbuild/deps/github.com" > "$S/mettle.deps"
ln -s "$S" "$S/.mbuild/deps/github.com/me/selfy"
"$DRV" "$S" linux prepare >"$W/s1" 2>&1 && ok "self import: prepare linux" || bad "self import: prepare linux" "$W/s1"
check "self import: the C library is built once" [ "$(grep -c '^arg -lmb_' "$W/s1")" = 1 ]
check "self import: no second library" [ ! -e "$S/.mbuild/cache/linux/lib/libmb_selfy_2.so" ]
mkdir -p "$S/build"
( cd "$S" && "$HEAD" --build cmd/demo/main.mettle -o build/demo $(args_of "$W/s1") ) >"$W/s1.cc" 2>&1
for f in $(copies_of "$W/s1"); do cp "$f" "$S/build/"; done
check "self import: cmd/demo runs (selfy=7)" [ "$("$S/build/demo" 2>&1)" = "selfy=7" ]
"$DRV" "$S" linux doctor >"$W/s2" 2>&1
check "self import: doctor counts the extern once" has "$W/s2" "linux: 1 extern"

echo
echo "r2_native: $pass passed, $fail failed"
[ $fail = 0 ]
