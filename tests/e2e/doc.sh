#!/bin/sh
# doc.sh: `mbuild doc` end to end (comment styles, fields, settings, --check findings, stale files, snippets, publish), mbuild built debug and --release.
#   METTLE=dev-compiler sh tests/e2e/doc.sh   (scratch: $MBTEST_TMP)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
S="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/doc}"
rm -rf "$S"
mkdir -p "$S"
export LC_ALL=C NO_COLOR=1 METTLE
unset MBUILD_COLOR
export MBUILD_HOME="$S/home"

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -40; }
check() { name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$S/last.out" 2>/dev/null)"; fi; }
has() { grep -qF -- "$1" "$S/last.out"; }
hasnt() { ! grep -qF -- "$1" "$S/last.out"; }
line() { grep -qxF -- "$1" "$S/last.out"; }
code_is() { [ "$(cat "$S/last.code")" = "$1" ]; }
mb() { "$MB" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }
# api LINE: the generated docs/API.md holds LINE exactly
api() { grep -qxF -- "$1" "${API:-docs/API.md}"; }
noapi() { ! grep -qF -- "$1" "${API:-docs/API.md}"; }

# proj DIR: a project named after DIR; stdin holds extra lines of fn project()
proj() {
  mkdir -p "$1/src"
  { printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("%s", "0.1.0");\n' "$(basename "$1")"; cat; printf '}\n'; } > "$1/mbuild.mettle"
}

for mode in ${MBTEST_MODES:-debug release}; do
flag=""
[ $mode = release ] && flag="--release"
echo "== mbuild ($mode)"
sh "$here/tools/mcompile.sh" $flag "$here/src/main.mettle" -o "$S/mbuild-$mode" >"$S/build-$mode.log" 2>&1 || { cat "$S/build-$mode.log"; exit 1; }
MB="$S/mbuild-$mode"
W="$S/$mode"
mkdir -p "$W"

# --- the comment styles: mistplot (///, @key, //!), cryptex (key:), flux_orm and alph (//)
proj "$W/styles" </dev/null
cd "$W/styles" || exit 1
cat > src/plot.mettle <<'EOF'
//! Rings and plots.
//! One module.

/// A ring of samples.
///
/// Keeps the newest ones.
///
/// @mem Owns its buffer.
export struct MpRing<T> {
  buf: T*;   /// the samples
  // how many
  n: int64;
}

/// Pushes one sample.
///
/// @param r The ring.
/// @param v The sample.
/// @return 1 when full.
/// @error -1 when r is 0.
/// @thread Not thread safe.
/// @cost O(1).
@inline
export fn mp_push(r: MpRing<float64>*, v: float64) -> int32 {
  return 0;
}

/// Not for users.
/// @internal
export fn mp_hidden() {
}

// TODO: a better name
/// Colours.
export enum MpColor {
  Red = 1,   // the red one
  Green,
}
EOF
cat > src/seal.mettle <<'EOF'
// seal: authenticated encryption.

/// Bytes a sealed message adds.
/// in: -
/// returns: 40
export const CR_OVERHEAD: int64 = 40;

/// Seals msg under key.
/// in: key and msg
/// returns: the sealed length,
///   never negative
/// owns: nothing
/// thread: any thread
/// example:
///   ```mettle ignore
///   cr_seal(k, m);
///   ```
export fn cr_seal(key: int64, msg: int64) -> int64 {
  return key + msg;
}
EOF
cat > src/orm.mettle <<'EOF'
import "std/mem";

// Finds a row by id.
//   db  the database
//   id  the row id
// Returns 0 when missing.
export fn fx_find(db: int64, id: int64) -> int64 {
  return db + id;
}
EOF
cat > src/zalph.mettle <<'EOF'
// Sends a request.
//
//   to          the server's pid
//   tag, arg    as al_send
//
// Returns the ref. Then arrives:
//
//   ALPH_TAG_DOWN   the server exited;
//                   arg = its exit reason
// Thread: a handler.
export fn al_request(to: int64, tag: int64, arg: int64) -> int64 {
  return to + tag + arg;
}
EOF
cat > src/internal.mettle <<'EOF'
//! @internal

/// Never shown.
export fn in_secret() {
}
EOF
mb doc
check "doc: writes docs/API.md" sh -c 'grep -qx "    Updating docs/API.md" "$0/last.out" && test -f docs/API.md' "$S"
check "doc: title" api "# styles API"
check "doc: module heading" api "## src/plot.mettle"
check "//!: module doc" api "Rings and plots."
check "///: struct with generics" api "struct MpRing<T> {"
check "///: struct field from a trailing ///" api '| `buf` | `T*` | the samples |'
check "//: struct field from the line above" api '| `n` | `int64` | how many |'
check "///: summary" api "Pushes one sample."
check "///: prose after the summary" api "Keeps the newest ones."
check "@param: listed" api '- `v`: The sample.'
check "@return: labelled" api "**Returns:** 1 when full."
check "@error: labelled" api "**Errors:** -1 when r is 0."
check "@mem: labelled" api "**Owns:** Owns its buffer."
check "@thread and @cost" sh -c 'grep -qxF "**Thread:** Not thread safe." docs/API.md && grep -qxF "**Cost:** O(1)." docs/API.md'
check "decorator between doc and fn" api "fn mp_push(r: MpRing<float64>*, v: float64) -> int32"
check "@internal fn left out" noapi "mp_hidden"
check "//! @internal module left out" noapi "in_secret"
check "a // line above a /// block is not doc" noapi "TODO"
check "enum variants table" api '| `Red = 1` | the red one |'
check "key: fields labelled" sh -c 'grep -qxF "**In:** key and msg" docs/API.md && grep -qxF "**Owns:** nothing" docs/API.md && grep -qxF "**Thread:** any thread" docs/API.md'
check "key: continuation lines" sh -c 'grep -A1 -xF "**Returns:** the sealed length," docs/API.md | grep -qxF "never negative"'
check "example: fenced block kept" sh -c 'grep -A3 -xF "**Example:**" docs/API.md | grep -qxF "cr_seal(k, m);"'
check "first comment paragraph is the module doc" api "seal: authenticated encryption."
check "//   name  meaning lines are params" api '- `id`: the row id'
check "// Returns ... is the returns field" api "**Returns:** Returns 0 when missing."
check "const declaration" api "const CR_OVERHEAD: int64"
check "alph: params after a blank line, two names on one line" sh -c 'grep -qxF -- "- \`tag\`: as al_send" docs/API.md && grep -qxF -- "- \`arg\`: as al_send" docs/API.md'
check "alph: indented lines after Returns stay prose" sh -c 'grep -qF "arg = its exit reason" docs/API.md && ! grep -qF -- "- \`arg\`: = its" docs/API.md'
check "alph: Thread: is a field" api "**Thread:** a handler."
mb doc
check "doc: unchanged is Fresh" line "       Fresh docs/API.md"
mb doc --check
check "--check: a fresh, documented package passes" sh -c '[ "$(cat "$0/last.code")" = 0 ] && grep -q "Checked docs/API.md (7 exports, 0 snippets)" "$0/last.out"' "$S"

# --- --check findings: undocumented, @param, required fields, stale
cat >> src/orm.mettle <<'EOF'

export fn fx_bare() {
}

/// Swaps.
/// @param b second
/// @param a first
/// @param c nope
export fn fx_swap(a: int64, b: int64) {
}

///
/// @return nothing
export fn fx_empty() -> int64 {
  return 0;
}
EOF
mb doc --check
check "--check: exit 1" code_is 1
check "--check: undocumented export" line "src/orm.mettle:11: fx_bare: no doc comment"
check "--check: @param out of order" line "src/orm.mettle:18: fx_swap: @param a is out of order (a, b)"
check "--check: @param not a parameter" line "src/orm.mettle:18: fx_swap: @param c is not a parameter (a, b)"
check "--check: empty summary" line "src/orm.mettle:23: fx_empty: the doc comment has no summary"
check "--check: stale file" line "docs/API.md:20: out of date; run \`mbuild doc\`"
check "--check: writes nothing" sh -c '! grep -q fx_bare docs/API.md'
mb doc
check "doc: findings are warnings" sh -c 'grep -qxF "warning: src/orm.mettle:11: fx_bare: no doc comment" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
mb doc --check
check "--check: no stale finding after doc" hasnt "out of date"
rm docs/API.md
mb doc --check
check "--check: missing file" line "docs/API.md:1: missing; run \`mbuild doc\`"
cd "$S" || exit 1

# --- mb_doc_require
proj "$W/req" <<'EOF2'
  mb_doc_require("param, returns, thread");
EOF2
cd "$W/req" || exit 1
cat > src/r.mettle <<'EOF'
/// Adds.
/// @param a left
export fn r_add(a: int32, b: int32) -> int32 {
  return a + b;
}

/// Nothing back.
/// in: the value
/// thread: any
export fn r_set(v: int32) {
}

/// A point.
export struct RPoint {
  x: int32;
}
EOF
mb doc && mb doc --check
check "require: missing @param" line "src/r.mettle:3: r_add: parameter b is not documented (@param)"
check "require: missing returns" line "src/r.mettle:3: r_add: no \`returns\` field (mb_doc_require)"
check "require: missing other field" line "src/r.mettle:3: r_add: no \`thread\` field (mb_doc_require)"
check "require: in: covers param, no returns needed without a value" hasnt "r_set"
check "require: fields only for functions" hasnt "RPoint"
sed -i 's/thread"/threads"/' mbuild.mettle
mb doc
check "require: unknown field" has "mb_doc_require: unknown field 'threads'"
cd "$S" || exit 1

# --- mb_doc_exports, mb_doc_facade, mb_doc_out
proj "$W/sel" <<'EOF2'
  mb_doc_exports("rz_, !rz_priv");
EOF2
cd "$W/sel" || exit 1
cat > src/a.mettle <<'EOF'
/// Kept.
export fn rz_get() {
}

/// Dropped by !.
export fn rz_priv_x() {
}

export fn other() {
}
EOF
mb doc
check "exports: findings only for kept names" sh -c '! grep -q "other\|rz_priv" "$0/last.out"' "$S"
check "exports: in the file" sh -c 'grep -qx "### rz_get" docs/API.md && ! grep -q "rz_priv\|### other" docs/API.md'
cd "$S" || exit 1

proj "$W/fac" <<'EOF2'
  mb_doc_facade("src/fac.mettle");
  mb_doc_out("API.md");
EOF2
cd "$W/fac" || exit 1
mkdir -p src/core
printf '//! The facade.\n\nimport "core/b";\nimport "a";\n' > src/fac.mettle
printf '/// From a.\nexport fn f_a() {\n}\n' > src/a.mettle
printf 'import "c";\n\n/// From b.\nexport fn f_b() {\n}\n' > src/core/b.mettle
printf '/// From c.\nexport fn f_c() {\n}\n' > src/core/c.mettle
printf '/// Not imported.\nexport fn f_x() {\n}\n' > src/x.mettle
mb doc
check "out: mb_doc_out" line "    Updating API.md"
API=API.md
check "facade: its module doc" api "The facade."
check "facade: imports in order, then theirs" sh -c '[ "$(grep "^## " API.md | tr "\n" " ")" = "## src/fac.mettle ## src/core/b.mettle ## src/a.mettle ## src/core/c.mettle " ]'
check "facade: other modules left out" noapi "f_x"
unset API
cd "$S" || exit 1

# --- snippets: doc comments and Markdown files, compiled by --check
proj "$W/snip" <<'EOF2'
  mb_doc_snippets("README.md");
EOF2
cd "$W/snip" || exit 1
cat > src/m.mettle <<'EOF'
/// Doubles.
///
/// ```mettle
/// var x: int32 = m_double(2);
/// println("{x}");
/// ```
///
/// ```mettle ignore
/// not code at all
/// ```
export fn m_double(v: int32) -> int32 {
  return v * 2;
}
EOF
printf '# snip\n\n```mettle\nimport "std/io";\n\nfn main() -> int32 {\n  println("hi");\n  return 0;\n}\n```\n' > README.md
mb doc && mb doc --check
check "snippets: compile" sh -c '[ "$(cat "$0/last.code")" = 0 ] && grep -q "Checked docs/API.md (1 exports, 2 snippets)" "$0/last.out"' "$S"
check "snippets: shown in the reference" api 'var x: int32 = m_double(2);'
printf '# snip\n\n```mettle\nfn main() -> int32 {\n  return nope();\n}\n```\n' > README.md
sed -i 's/m_double(2)/m_triple(2)/' src/m.mettle
mb doc && mb doc --check
check "snippets: a failing block is an error" sh -c '[ "$(cat "$0/last.code")" = 1 ] && grep -q "Undefined function .m_triple" "$0/last.out"' "$S"
check "snippets: doc block named by file:line" line "error: src/m.mettle:3: the \`\`\`mettle block does not compile (.mbuild/doc/snip/1.mettle)"
check "snippets: Markdown block named by file:line" line "error: README.md:3: the \`\`\`mettle block does not compile (.mbuild/doc/snip/2.mettle)"
check "snippets: ignore is not compiled" hasnt "not code"
cd "$S" || exit 1

# --- publish runs doc --check when mb_doc_out is set
proj "$W/pub" <<'EOF2'
  mb_doc_out("docs/API.md");
EOF2
cd "$W/pub" || exit 1
printf '/// Documented.\nexport fn p_one() {\n}\n\nexport fn p_two() {\n}\n' > src/pub.mettle
"$MB" registry init "$W/reg" >"$S/last.out" 2>&1
mb doc
mb publish --to "$W/reg" --dry-run
check "publish: doc --check fails it" sh -c '[ "$(cat "$0/last.code")" = 1 ] && grep -q "src/pub.mettle:5: p_two: no doc comment" "$0/last.out"' "$S"
printf '/// Documented.\nexport fn p_one() {\n}\n\n/// Two.\nexport fn p_two() {\n}\n' > src/pub.mettle
mb doc
mb publish --to "$W/reg" --dry-run
check "publish: passes doc --check first" sh -c 'grep -q "Checked docs/API.md" "$0/last.out" && grep -q "without init.rules" "$0/last.out"' "$S"
cd "$S" || exit 1

mb help doc
check "help doc" has "usage: mbuild doc [--check]"
done

echo "doc: $pass passed, $failed failed"
[ $failed = 0 ]
