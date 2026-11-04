#!/bin/sh
# make-registry.sh ROOT: a file registry at ROOT/registry built with tar + sha256sum only.
set -eu
ROOT=$(mkdir -p "$1" && cd "$1" && pwd); REG="$ROOT/registry"; SRC="$ROOT/src"
rm -rf "$REG" "$SRC"; mkdir -p "$REG/index" "$REG/pkg" "$SRC"
printf '[registry]\nformat = 1\nname = "fixtures"\n' > "$REG/registry.toml"
# pkg NAME VERSION: package files are in $SRC/NAME-VERSION (its mbuild.toml is the manifest)
pkg() {
  d="$SRC/$1-$2"; out="$REG/pkg/$1"; mkdir -p "$out"
  ( cd "$d" && find . -type f ! -name mbuild.toml | sed 's|^\./||' | LC_ALL=C sort > "$SRC/.list" && tar -czf "$out/$1-$2.tar.gz" -T "$SRC/.list" )
  cp "$d/mbuild.toml" "$out/$1-$2.toml"
  a=$(sha256sum "$out/$1-$2.tar.gz" | cut -c1-64); m=$(sha256sum "$out/$1-$2.toml" | cut -c1-64)
  [ -f "$REG/index/$1" ] || printf '# mbuild index %s\n' "$1" > "$REG/index/$1"
  printf '%s sha256=%s manifest=%s\n' "$2" "$a" "$m" >> "$REG/index/$1"
}
mk() { # NAME VERSION [manifest lines after [package] on stdin]
  d="$SRC/$1-$2"; mkdir -p "$d"
  { printf '[package]\nname = "%s"\nversion = "%s"\n' "$1" "$2"; cat; } > "$d/mbuild.toml"
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
