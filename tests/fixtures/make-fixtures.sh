#!/bin/sh
# Builds local git repositories that stand in for GitHub packages, and an app
# that depends on them. Point mbuild at them with MBUILD_GIT_BASE.
#
#   tests/fixtures/make-fixtures.sh [ROOT]      (default /tmp/opencode/fixtures)
#
#   ROOT/gitbase/github.com/demo/strutil     pure Mettle; tags v1.0.0 v1.1.0 v2.0.0-rc.1
#   ROOT/gitbase/github.com/demo/vecmath     Mettle + C (csrc/vec.c, libm); needs strutil
#                                            v0.1.0 -> strutil v1.0.0, v0.2.0 -> strutil v1.1.0
#   ROOT/gitbase/github.com/demo/nomanifest  no mbuild.toml, no tags, branch main
#   ROOT/app                                 imports all three; only vecmath is declared
#
# Then: MBUILD_GIT_BASE=ROOT/gitbase mbuild build   (inside ROOT/app)

set -eu
ROOT="${1:-/tmp/opencode/fixtures}"
rm -rf "$ROOT"
mkdir -p "$ROOT/gitbase/github.com/demo"
G="$ROOT/gitbase/github.com/demo"

git_init() {
  git init -q -b main "$1"
  git -C "$1" config user.email fixtures@mbuild.test
  git -C "$1" config user.name "mbuild fixtures"
}
commit_tag() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
  [ -z "${3:-}" ] || git -C "$1" tag "$3"
}

# --- strutil -----------------------------------------------------------------
R="$G/strutil"
git_init "$R"
cat > "$R/mbuild.toml" <<'EOF'
[package]
name = "strutil"
module = "github.com/demo/strutil"
version = "1.0.0"
EOF
cat > "$R/strutil.mettle" <<'EOF'
export fn su_shout(s: string) -> string {
  return s + "!";
}

export fn su_version() -> string {
  return "strutil v1.0.0";
}
EOF
commit_tag "$R" "strutil 1.0.0" v1.0.0
sed -i 's/1.0.0/1.1.0/' "$R/mbuild.toml" "$R/strutil.mettle"
cat >> "$R/strutil.mettle" <<'EOF'

export fn su_twice(s: string) -> string {
  return s + s;
}
EOF
commit_tag "$R" "strutil 1.1.0" v1.1.0
sed -i 's/1.1.0/2.0.0-rc.1/' "$R/mbuild.toml" "$R/strutil.mettle"
commit_tag "$R" "strutil 2.0.0-rc.1" v2.0.0-rc.1

# --- vecmath -----------------------------------------------------------------
R="$G/vecmath"
git_init "$R"
mkdir -p "$R/csrc/include"
cat > "$R/csrc/include/vec.h" <<'EOF'
typedef struct { float x, y; } Vec2;
float vm_dot(Vec2 a, Vec2 b);
float vm_len(Vec2 a);
Vec2 vm_scale(Vec2 a, float k);
EOF
cat > "$R/csrc/vec.c" <<'EOF'
#include <math.h>
#include "vec.h"
float vm_dot(Vec2 a, Vec2 b) { return a.x * b.x + a.y * b.y; }
float vm_len(Vec2 a) { return sqrtf(vm_dot(a, a)); }
Vec2 vm_scale(Vec2 a, float k) { Vec2 r = { a.x * k, a.y * k }; return r; }
EOF
cat > "$R/mbuild.toml" <<'EOF'
[package]
name = "vecmath"
module = "github.com/demo/vecmath"
version = "0.1.0"

[dependencies]
"github.com/demo/strutil" = "v1.0.0"

[c]
sources = ["csrc"]
include = ["csrc/include"]
cflags = ["-O2"]

[c.linux]
libs = ["m"]
EOF
cat > "$R/vecmath.mettle" <<'EOF'
import "github.com/demo/strutil/strutil";

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
EOF
commit_tag "$R" "vecmath 0.1.0" v0.1.0
sed -i 's/version = "0.1.0"/version = "0.2.0"/; s/strutil" = "v1.0.0"/strutil" = "v1.1.0"/' "$R/mbuild.toml"
commit_tag "$R" "vecmath 0.2.0" v0.2.0

# --- nomanifest --------------------------------------------------------------
R="$G/nomanifest"
git_init "$R"
cat > "$R/greet.mettle" <<'EOF'
export fn greet(who: string) -> string {
  return "hello, " + who;
}
EOF
commit_tag "$R" "greet" ""

# --- app ---------------------------------------------------------------------
A="$ROOT/app"
mkdir -p "$A/src"
cat > "$A/mbuild.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
"github.com/demo/vecmath" = "v0.1.0"
EOF
cat > "$A/src/main.mettle" <<'EOF'
import "std/io";
import "github.com/demo/vecmath/vecmath";
import "github.com/demo/strutil/strutil";
import "github.com/demo/nomanifest/greet";

fn main() -> int32 {
  var a: Vec2 = { x: 3.0, y: 4.0 };
  var b: Vec2 = vm_scale(a, (float32)2.0);
  println("{vm_banner()} {su_version()} dot={vm_dot(a, b)} len={vm_len(a)}");
  println(greet("mbuild"));
  return 0;
}
EOF
echo "fixtures ready in $ROOT"
