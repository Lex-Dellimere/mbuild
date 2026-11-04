#!/bin/sh
# make-mettle-registry.sh ROOT: a registry in the Mettle project's format at
# ROOT/mreg: v1/index.json and plain tar archives in v1/archives (tar + sha256sum only).
# textkit 1.0.0 and 1.1.0, greet 1.0.0 (requires textkit 1.0.0), badsha 1.0.0 (its index
# hash is wrong), evil 1.0.0 (holds a symlink), old 1.0.0 (yanked).
set -eu
ROOT=$(mkdir -p "$1" && cd "$1" && pwd); REG="$ROOT/mreg"; SRC="$ROOT/msrc"
rm -rf "$REG" "$SRC"; mkdir -p "$REG/v1/archives" "$SRC"
# pkg NAME VERSION [REQUIRES-JSON [YANKED [SHA]]]: archives $SRC/NAME-VERSION, adds its
# version entry to $SRC/NAME.versions
pkg() {
  d="$SRC/$1-$2"; a="archives/$1-$2.tar"; req=${3:-}; [ -n "$req" ] || req='{}'
  ( cd "$d" && find . ! -type d | sed 's|^\./||' | LC_ALL=C sort > "$SRC/.list" && tar --format=ustar -cf "$REG/v1/$a" -T "$SRC/.list" )
  sha=${5:-$(sha256sum "$REG/v1/$a" | cut -c1-64)}
  [ -f "$SRC/$1.versions" ] && printf ', ' >> "$SRC/$1.versions"
  printf '{"version": "%s", "sha256": "%s", "size": %s, "published": "2026-11-04", "yanked": %s, "compiler": null, "requires": %s, "archive": "%s"}' \
    "$2" "$sha" "$(wc -c <"$REG/v1/$a")" "${4:-false}" "$req" "$a" >> "$SRC/$1.versions"
  echo "$1 $2" >> "$SRC/.latest"
}
# mk NAME VERSION [REQUIRE-LINES]: mettle.package and README in $SRC/NAME-VERSION
mk() {
  d="$SRC/$1-$2"; mkdir -p "$d"
  printf 'name = %s\nversion = %s\ndescription = %s test package\nlicense = MIT\nsource = https://example.com/%s\n%s' "$1" "$2" "$1" "$1" "${3:-}" > "$d/mettle.package"
  printf '# %s\n' "$1" > "$d/README.md"
}

for v in 1.0.0 1.1.0; do
  mk textkit $v
  printf 'export fn tk_shout(s: string) -> string {\n  return s + "!";\n}\n\nexport fn tk_version() -> string {\n  return "textkit %s";\n}\n' $v > "$SRC/textkit-$v/textkit.mettle"
  printf 'export fn tk_twice(s: string) -> string {\n  return s + s;\n}\n' > "$SRC/textkit-$v/extra.mettle"
done
pkg textkit 1.0.0
pkg textkit 1.1.0

mk greet 1.0.0 'require = textkit 1.0.0
'
printf 'import "textkit/textkit";\n\nexport fn gr_hello(name: string) -> string {\n  var s: string = "hello " + name;\n  return tk_shout(s);\n}\n' > "$SRC/greet-1.0.0/greet.mettle"
pkg greet 1.0.0 '{"textkit": "1.0.0"}'

mk badsha 1.0.0
printf 'export fn bs_x() -> int32 {\n  return 1;\n}\n' > "$SRC/badsha-1.0.0/badsha.mettle"
pkg badsha 1.0.0 '{}' false 0000000000000000000000000000000000000000000000000000000000000000

mk evil 1.0.0
printf 'export fn ev_x() -> int32 {\n  return 1;\n}\n' > "$SRC/evil-1.0.0/evil.mettle"
ln -s /etc/passwd "$SRC/evil-1.0.0/passwd"
pkg evil 1.0.0

mk old 1.0.0
printf 'export fn old_x() -> int32 {\n  return 1;\n}\n' > "$SRC/old-1.0.0/old.mettle"
pkg old 1.0.0 '{}' true

{
  printf '{\n  "format": 1,\n  "packages": ['
  sep=""
  for n in $(cut -d' ' -f1 "$SRC/.latest" | uniq); do
    printf '%s\n    {"name": "%s", "latest": "%s", "description": "the \\"%s\\" package \\u00e9\\ud83d\\ude00",\n     "license": "MIT", "source": "https://example.com/%s", "versions": [%s]}' \
      "$sep" "$n" "$(grep "^$n " "$SRC/.latest" | tail -1 | cut -d' ' -f2)" "$n" "$n" "$(cat "$SRC/$n.versions")"
    sep=","
  done
  printf '\n  ]\n}\n'
} > "$REG/v1/index.json"
