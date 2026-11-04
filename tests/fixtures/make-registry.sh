#!/bin/sh
# make-registry.sh ROOT: a file registry at ROOT/registry built with tar + sha256sum only.
set -eu
ROOT=$(mkdir -p "$1" && cd "$1" && pwd); REG="$ROOT/registry"; SRC="$ROOT/src"
rm -rf "$REG" "$SRC"; mkdir -p "$REG/index" "$REG/pkg" "$SRC"
printf '[registry]\nformat = 1\nname = "fixtures"\n' > "$REG/registry.toml"
# pkg NAME VERSION: package files are in $SRC/NAME-VERSION; its manifest.toml is the
# frozen manifest the registry serves (14.7), not a user file, and stays out of the archive
pkg() {
  d="$SRC/$1-$2"; out="$REG/pkg/$1"; mkdir -p "$out"
  ( cd "$d" && find . -type f ! -name manifest.toml | sed 's|^\./||' | LC_ALL=C sort > "$SRC/.list" && tar -czf "$out/$1-$2.tar.gz" -T "$SRC/.list" )
  cp "$d/manifest.toml" "$out/$1-$2.toml"
  a=$(sha256sum "$out/$1-$2.tar.gz" | cut -c1-64); m=$(sha256sum "$out/$1-$2.toml" | cut -c1-64)
  [ -f "$REG/index/$1" ] || printf '# mbuild index %s\n' "$1" > "$REG/index/$1"
  printf '%s sha256=%s manifest=%s\n' "$2" "$a" "$m" >> "$REG/index/$1"
}
mk() { # NAME VERSION [frozen manifest lines after [package] on stdin]
  d="$SRC/$1-$2"; mkdir -p "$d"
  { printf '[package]\nname = "%s"\nversion = "%s"\n' "$1" "$2"; cat; } > "$d/manifest.toml"
}

# --- strutil: v1.0.0, v1.1.0 (adds su_twice), v2.0.0-rc.1 --------------------
for v in v1.0.0 v1.1.0 v2.0.0-rc.1; do
  mk strutil $v </dev/null
  cat > "$SRC/strutil-$v/strutil.mettle" <<EOF
export fn su_shout(s: string) -> string {
  return s + "!";
}

export fn su_version() -> string {
  return "strutil $v";
}
EOF
  if [ $v != v1.0.0 ]; then
    cat >> "$SRC/strutil-$v/strutil.mettle" <<'EOF'

export fn su_twice(s: string) -> string {
  return s + s;
}
EOF
  fi
  printf 'strutil: string helpers. Every function is pure.\n' > "$SRC/strutil-$v/AGENT.rules"
  pkg strutil $v
done

# --- textfmt -> strutil v1.1.0 -------------------------------------------------
mk textfmt v0.1.0 <<'EOF'
description = "text formatting"

[dependencies]
strutil = "v1.1.0"
EOF
cat > "$SRC/textfmt-v0.1.0/textfmt.mettle" <<'EOF'
import "strutil/strutil";

export fn tf_banner(s: string) -> string {
  return su_twice(su_shout(s));
}
EOF
printf 'textfmt: formatting over strutil.\n' > "$SRC/textfmt-v0.1.0/AGENT.rules"
pkg textfmt v0.1.0

# --- vecmath (C + libm): v0.1.0 -> strutil v1.0.0, v0.2.0 and v0.3.0 -> v1.1.0
for v in v0.1.0 v0.2.0 v0.3.0; do
  su=v1.1.0; [ $v = v0.1.0 ] && su=v1.0.0
  mk vecmath $v <<EOF

[dependencies]
strutil = "$su"

[c]
sources = ["csrc"]
include = ["csrc/include"]
cflags = ["-O2"]

[c.linux]
libs = ["m"]
EOF
  d="$SRC/vecmath-$v"; mkdir -p "$d/csrc/include"
  cat > "$d/csrc/include/vec.h" <<'EOF'
typedef struct { float x, y; } Vec2;
float vm_dot(Vec2 a, Vec2 b);
float vm_len(Vec2 a);
Vec2 vm_scale(Vec2 a, float k);
EOF
  cat > "$d/csrc/vec.c" <<'EOF'
#include <math.h>
#include "vec.h"
float vm_dot(Vec2 a, Vec2 b) { return a.x * b.x + a.y * b.y; }
float vm_len(Vec2 a) { return sqrtf(vm_dot(a, a)); }
Vec2 vm_scale(Vec2 a, float k) { Vec2 r = { a.x * k, a.y * k }; return r; }
EOF
  cat > "$d/vecmath.mettle" <<'EOF'
import "strutil/strutil";

export struct Vec2 {
  x: float32;
  y: float32;
}

export extern fn vm_dot(a: Vec2, b: Vec2) -> float32 = "vm_dot";
export extern fn vm_len(a: Vec2) -> float32 = "vm_len";
export extern fn vm_scale(a: Vec2, k: float32) -> Vec2 = "vm_scale";

export fn vm_banner() -> string {
  return su_shout("vecmath");
}

export fn vm_one() -> int32 {
  return 1;
}
EOF
  pkg vecmath $v
done

# --- apilib: v1.0.0, v1.1.0 (adds), v1.2.0 (breaks inside v1), v2.0.0 ---------
src() { mkdir -p "$SRC/$1-$2"; cat > "$SRC/$1-$2/$1.mettle"; }
for v in v1.0.0 v1.1.0 v1.2.0 v2.0.0; do mk apilib $v </dev/null; done
src apilib v1.0.0 <<'EOF'
export struct AlPair { a: int32; b: int32; }
export fn al_add(a: int32, b: int32) -> int32 { return a + b; }
export fn al_mul(a: int32, b: int32) -> int32 { return a * b; }
EOF
{ cat "$SRC/apilib-v1.0.0/apilib.mettle"; printf 'export fn al_sub(a: int32, b: int32) -> int32 { return a - b; }\n'; } | src apilib v1.1.0
src apilib v1.2.0 <<'EOF'
export struct AlPair { a: int32; b: int32; }
export fn al_add(a: int32, b: int32, c: int32) -> int32 { return a + b + c; }
export fn al_sub(a: int32, b: int32) -> int32 { return a - b; }
EOF
src apilib v2.0.0 <<'EOF'
export fn al2_add(a: int32, b: int32) -> int32 { return a + b; }
EOF
for v in v1.0.0 v1.1.0 v1.2.0 v2.0.0; do pkg apilib $v; done

# --- zero: v0 lines -----------------------------------------------------------
for v in v0.1.0 v0.1.1 v0.2.0; do mk zero $v </dev/null; done
printf 'export fn z_one() -> int32 { return 1; }\n' | src zero v0.1.0
printf 'export fn z_one() -> int32 { return 1; }\nexport fn z_two() -> int32 { return 2; }\n' | src zero v0.1.1
printf 'export fn z_two() -> int32 { return 2; }\n' | src zero v0.2.0
for v in v0.1.0 v0.1.1 v0.2.0; do pkg zero $v; done

# --- requirers ---------------------------------------------------------------
req() { # NAME VERSION DEP DEP-VERSION; source on stdin
  printf '\n[dependencies]\n%s = "%s"\n' "$3" "$4" | mk "$1" "$2"
  src "$1" "$2"
  pkg "$1" "$2"
}
printf 'import "apilib/apilib";\nexport fn old_val() -> int32 { return al_add(1, 2); }\n' | req old v1.0.0 apilib v1.0.0
printf 'import "apilib/apilib";\nexport fn old_val() -> int32 { return al2_add(1, 2); }\n' | req old v1.1.0 apilib v2.0.0
printf 'import "apilib/apilib";\nexport fn new2_val() -> int32 { return al2_add(2, 2); }\n' | req new2 v1.0.0 apilib v2.0.0
printf 'import "zero/zero";\nexport fn z1_val() -> int32 { return z_one(); }\n' | req z1 v1.0.0 zero v0.1.0
printf 'import "zero/zero";\nexport fn z2_val() -> int32 { return z_two(); }\n' | req z2 v1.0.0 zero v0.2.0

# --- needs: a minimum Mettle release ------------------------------------------
printf 'mettle = "v0.17.0"\n' | mk needs v0.9.0
printf 'mettle = "v0.99.0"\n' | mk needs v1.0.0
for v in v0.9.0 v1.0.0; do
  printf 'export fn needs_val() -> int32 { return 9; }\n' | src needs $v
  pkg needs $v
done

# --- same C symbol in two packages; same exported Mettle name in two ----------
for n in 1 2; do
  printf '\n[c]\nsources = ["dup.c"]\n' | mk cdup$n v1.0.0
  printf 'int dup_value(void) { return %s; }\nint cdup%s_only(void) { return dup_value(); }\n' $n $n > "$SRC/cdup$n-v1.0.0/dup.c"
  printf 'export extern fn cdup%s_only() -> int32 = "cdup%s_only";\n' $n $n | src cdup$n v1.0.0
  pkg cdup$n v1.0.0
  mk clash$n v1.0.0 </dev/null
  printf 'export fn clash_name() -> int32 { return %s; }\n' $n | src clash$n v1.0.0
  pkg clash$n v1.0.0
done

# --- yanky: v1.0.0, v1.0.1 yanked ---------------------------------------------
for v in v1.0.0 v1.0.1; do
  mk yanky $v </dev/null
  printf 'export fn yk_version() -> string {\n  return "yanky %s";\n}\n' $v > "$SRC/yanky-$v/yanky.mettle"
  pkg yanky $v
done
sed -i 's/^\(v1\.0\.1 .*\)$/\1 yanked/' "$REG/index/yanky"

# --- broken archives: evil (a symlink member), dotdot (a ../x member), badsum --
# bad NAME: archive already in $REG/pkg/NAME/NAME-v1.0.0.tar.gz, indexed as is.
bad() {
  out="$REG/pkg/$1"
  printf '[package]\nname = "%s"\nversion = "v1.0.0"\n' "$1" > "$out/$1-v1.0.0.toml"
  a=$(sha256sum "$out/$1-v1.0.0.tar.gz" | cut -c1-64); m=$(sha256sum "$out/$1-v1.0.0.toml" | cut -c1-64)
  printf '# mbuild index %s\nv1.0.0 sha256=%s manifest=%s\n' "$1" "$a" "$m" > "$REG/index/$1"
}
d="$SRC/evil"; mkdir -p "$d" "$REG/pkg/evil"
printf 'export fn ev() -> int32 {\n  return 1;\n}\n' > "$d/evil.mettle"
ln -s /etc/passwd "$d/passwd"
( cd "$d" && tar -czf "$REG/pkg/evil/evil-v1.0.0.tar.gz" evil.mettle passwd )
bad evil
d="$SRC/dotdot/pkg"; mkdir -p "$d" "$REG/pkg/dotdot"
printf 'export fn dd() -> int32 {\n  return 1;\n}\n' > "$d/dotdot.mettle"
printf 'outside\n' > "$SRC/dotdot/x"
( cd "$d" && tar -czPf "$REG/pkg/dotdot/dotdot-v1.0.0.tar.gz" dotdot.mettle ../x )
bad dotdot
mk badsum v1.0.0 </dev/null
printf 'export fn bs() -> int32 {\n  return 1;\n}\n' > "$SRC/badsum-v1.0.0/badsum.mettle"
pkg badsum v1.0.0
sed -i 's/sha256=[0-9a-f]*/sha256=9f8e7d6c5b4a39210f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a6978/' "$REG/index/badsum"
