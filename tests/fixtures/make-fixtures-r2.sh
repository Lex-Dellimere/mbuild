#!/bin/sh
# Round-2 fixtures, added to a ROOT made by make-fixtures.sh:
#   tests/fixtures/make-fixtures-r2.sh ROOT
set -eu
ROOT="$1"
G="$ROOT/gitbase/github.com/demo"
[ -d "$G/strutil" ] || { echo "run make-fixtures.sh $ROOT first" >&2; exit 1; }

git_init() {
  rm -rf "$1"
  git init -q -b main "$1"
  git -C "$1" config user.email fixtures@mbuild.test
  git -C "$1" config user.name "mbuild fixtures"
}
commit_tag() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
  [ -z "${3:-}" ] || git -C "$1" tag -a "$3" -m "$2"
}
sub_add() { # repo url path
  git -C "$1" -c protocol.file.allow=always submodule add -q "$2" "$3"
}
manifest() { # repo name [extra lines on stdin]
  { printf '[package]\nname = "%s"\nmodule = "github.com/demo/%s"\n' "$2" "$2"; cat; } > "$1/mbuild.toml"
}

# --- submodules: wrapper -> vendor/clib (../clib) -> third_party/deep (../deep)
R="$G/deep"; git_init "$R"; mkdir -p "$R/include"
printf '#define DEEP_VALUE 7\n' > "$R/include/deep.h"
commit_tag "$R" "deep 1" v1.0.0

R="$G/clib"; git_init "$R"
printf '#include "deep.h"\nint clib_value(void) { return DEEP_VALUE * 6; }\n' > "$R/clib.c"
sub_add "$R" ../deep third_party/deep
commit_tag "$R" "clib 1.0.0" v1.0.0
sed -i 's/\* 6/* 6 + 1/' "$R/clib.c"
commit_tag "$R" "clib 1.1.0" v1.1.0

R="$G/wrapper"; git_init "$R"
manifest "$R" wrapper <<'EOF'

[c]
sources = ["vendor/clib/clib.c"]
include = ["vendor/clib/third_party/deep/include"]
EOF
printf 'export extern fn clib_value() -> int32 = "clib_value";\n' > "$R/wrapper.mettle"
sub_add "$R" ../clib vendor/clib
git -C "$R/vendor/clib" checkout -q v1.0.0
commit_tag "$R" "wrapper 1.0.0 (clib 1.0.0 = 42)" v1.0.0
git -C "$R/vendor/clib" checkout -q v1.1.0
commit_tag "$R" "wrapper 1.1.0 (clib 1.1.0 = 43)" v1.1.0

R="$G/absurl"; git_init "$R"
manifest "$R" absurl <<'EOF'

[c]
sources = ["clib/clib.c"]
include = ["clib/third_party/deep/include"]
EOF
printf 'export extern fn clib_value() -> int32 = "clib_value";\n' > "$R/absurl.mettle"
sub_add "$R" "$G/clib" clib
commit_tag "$R" "absurl 1.0.0" v1.0.0

# --- apilib: v1.0.0, v1.1.0 (adds), v1.2.0 (breaks inside v1), v2.0.0 ---------
R="$G/apilib"; git_init "$R"
manifest "$R" apilib </dev/null
cat > "$R/apilib.mettle" <<'EOF'
export struct AlPair { a: int32; b: int32; }
export fn al_add(a: int32, b: int32) -> int32 { return a + b; }
export fn al_mul(a: int32, b: int32) -> int32 { return a * b; }
EOF
commit_tag "$R" "apilib 1.0.0" v1.0.0
printf 'export fn al_sub(a: int32, b: int32) -> int32 { return a - b; }\n' >> "$R/apilib.mettle"
commit_tag "$R" "apilib 1.1.0: add al_sub" v1.1.0
cat > "$R/apilib.mettle" <<'EOF'
export struct AlPair { a: int32; b: int32; }
export fn al_add(a: int32, b: int32, c: int32) -> int32 { return a + b + c; }
export fn al_sub(a: int32, b: int32) -> int32 { return a - b; }
EOF
commit_tag "$R" "apilib 1.2.0: al_add takes 3, al_mul removed" v1.2.0
cat > "$R/apilib.mettle" <<'EOF'
export fn al2_add(a: int32, b: int32) -> int32 { return a + b; }
EOF
commit_tag "$R" "apilib 2.0.0" v2.0.0

# --- zero: v0 lines -----------------------------------------------------------
R="$G/zero"; git_init "$R"
manifest "$R" zero </dev/null
printf 'export fn z_one() -> int32 { return 1; }\n' > "$R/zero.mettle"
commit_tag "$R" "zero 0.1.0" v0.1.0
printf 'export fn z_two() -> int32 { return 2; }\n' >> "$R/zero.mettle"
commit_tag "$R" "zero 0.1.1" v0.1.1
printf 'export fn z_two() -> int32 { return 2; }\n' > "$R/zero.mettle"
commit_tag "$R" "zero 0.2.0: z_one removed" v0.2.0

# --- requirers ---------------------------------------------------------------
req_pkg() { # name module-req version-req tag body
  R="$G/$1"; [ -d "$R/.git" ] || git_init "$R"
  manifest "$R" "$1" <<EOF

[dependencies]
"github.com/demo/$2" = "$3"
EOF
  printf '%s\n' "$5" > "$R/$1.mettle"
  commit_tag "$R" "$1 $4" "$4"
}
req_pkg old apilib v1.0.0 v1.0.0 'import "github.com/demo/apilib/apilib";
export fn old_val() -> int32 { return al_add(1, 2); }'
req_pkg old apilib v2.0.0 v1.1.0 'import "github.com/demo/apilib/apilib";
export fn old_val() -> int32 { return al2_add(1, 2); }'
req_pkg new2 apilib v2.0.0 v1.0.0 'import "github.com/demo/apilib/apilib";
export fn new2_val() -> int32 { return al2_add(2, 2); }'
req_pkg z1 zero v0.1.0 v1.0.0 'import "github.com/demo/zero/zero";
export fn z1_val() -> int32 { return z_one(); }'
req_pkg z2 zero v0.2.0 v1.0.0 'import "github.com/demo/zero/zero";
export fn z2_val() -> int32 { return z_two(); }'

# --- needs: a minimum Mettle release ------------------------------------------
R="$G/needs"; git_init "$R"
manifest "$R" needs <<'EOF'
mettle = "v0.17.0"
EOF
printf 'export fn needs_val() -> int32 { return 9; }\n' > "$R/needs.mettle"
commit_tag "$R" "needs 0.9.0" v0.9.0
sed -i 's/v0.17.0/v0.99.0/' "$R/mbuild.toml"
commit_tag "$R" "needs 1.0.0 (Mettle v0.99.0)" v1.0.0

# --- same C symbol in two packages; same exported Mettle name in two ----------
for n in 1 2; do
  R="$G/cdup$n"; git_init "$R"
  manifest "$R" "cdup$n" <<'EOF'

[c]
sources = ["dup.c"]
EOF
  printf 'int dup_value(void) { return %s; }\nint cdup%s_only(void) { return dup_value(); }\n' "$n" "$n" > "$R/dup.c"
  printf 'export extern fn cdup%s_only() -> int32 = "cdup%s_only";\n' "$n" "$n" > "$R/cdup$n.mettle"
  commit_tag "$R" "cdup$n" v1.0.0
  R="$G/clash$n"; git_init "$R"
  manifest "$R" "clash$n" </dev/null
  printf 'export fn clash_name() -> int32 { return %s; }\n' "$n" > "$R/clash$n.mettle"
  commit_tag "$R" "clash$n" v1.0.0
done
echo "round-2 fixtures ready in $ROOT"
