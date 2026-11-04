#!/bin/sh
# init.sh: init.rules and AGENT.rules (tests/unit/init_test.mettle and the CLI).
#   METTLE=dev-compiler sh tests/e2e/init.sh   (scratch: $MBTEST_TMP)

set -u
here="${MBTEST_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
export METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
T="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/init}"
rm -rf "$T"
mkdir -p "$T"
export MBUILD_HOME="$T/home"
export MBUILD_REGISTRY="$T/registry"

pass=0
failn=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /'; }
expect_line() {
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else bad "$1 (wanted line: $3)" "$2"; fi
}
expect_has() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (wanted: $3)" "$2"; fi
}
expect_no() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then bad "$1 (unwanted: $3)" "$2"; else ok "$1"; fi
}
file_has() {
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1 ($2 lacks: $3)" "$(cat "$2" 2>/dev/null)"; fi
}
file_lacks() {
  if [ -f "$2" ] && ! grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1 ($2 has: $3)" "$(cat "$2" 2>/dev/null)"; fi
}

# --- fixtures ------------------------------------------------------------------

# The registry fixtures; W is webfw as a path package.
sh "$here/tests/fixtures/make-registry.sh" "$T" >/dev/null || exit 1
REG="$T/registry"
SRC="$T/src"
W="$T/webfw-src"
cp -r "$SRC/webfw-v1.0.0" "$W"
rm "$W/manifest.toml"

# --- part 1: the driver --------------------------------------------------------

echo "== building the driver"
DRV="$T/drv"
mkdir -p "$DRV"
for v in debug release; do
  flag=""
  [ "$v" = release ] && flag="--release"
  if "$METTLE" --build $flag "$here/tests/unit/init_test.mettle" -o "$DRV/init_driver.$v" > "$DRV/$v.log" 2>&1; then
    if grep -q "warning" "$DRV/$v.log"; then bad "driver ($v) compiles without warnings" "$(cat "$DRV/$v.log")"; else ok "driver ($v) compiles without warnings"; fi
  else
    bad "driver ($v) compiles" "$(cat "$DRV/$v.log")"
    exit 1
  fi
done

for v in debug release; do
echo "== part 1 ($v)"
D="$DRV/init_driver.$v"
rm -rf "$MBUILD_HOME"
P="$T/p1-$v"
mkdir -p "$P"
cd "$P" || exit 1

out=$("$D" . selftest 2>&1); rc=$?
if [ $rc -eq 0 ]; then ok "agt_strip_block checks"; else bad "agt_strip_block checks" "$out"; fi
out=$("$D" . api 2>&1)
expect_has "ini_api_text is the shipped API" "$out" "export fn mi_option(name: string, dflt: string, help: string)"

out=$("$D" . new site --from "$W" --opt port=9000 --yes 2>&1); rc=$?
expect_line "new: mbuild.mettle line" "$out" "     Created site/mbuild.mettle (package \`site\`, depends on webfw (path), sqlite v1.2.0)"
expect_line "new: files line" "$out" "     Created site/src/main.mettle, site/src/routes.mettle, site/static/"
expect_line "new: command line" "$out" "     Command serve: run the dev server on port 9000"
expect_line "new: next line" "$out" "  next: mbuild serve, then open http://localhost:9000"
[ $rc -eq 0 ] && ok "new exits 0" || bad "new exits 0 (got $rc)" "$out"
file_has "routes.mettle has the port" site/src/routes.mettle 'return "9000";'
file_has "template variables" site/src/main.mettle "// site, started from webfw v1.0.0 (mbuild 0.2.0); @@ stays"
file_has "mbuild.mettle depends on webfw" site/mbuild.mettle "mb_dep_path(\"webfw\", \"$W\");"
file_has "mbuild.mettle depends on sqlite" site/mbuild.mettle 'mb_dep("sqlite", "v1.2.0");'
file_has "mbuild.mettle release profile" site/mbuild.mettle 'mb_profile("release");'
file_has "mbuild.mettle release setting" site/mbuild.mettle 'mb_set("optimize", "full");'
file_has "mbuild.mettle cmd_serve" site/mbuild.mettle 'return mb_mbuild("run -- --port 9000");'
file_lacks "no example command" site/mbuild.mettle "cmd_hello"
[ -d site/static ] && ok "static/ created" || bad "static/ created"
file_has ".gitignore" site/.gitignore "/.mbuild/"

out=$("$D" . new site2 --from "$W" --opt db=memory --yes 2>&1)
file_lacks "db=memory: no sqlite dep" site2/mbuild.mettle "sqlite"
out=$("$D" . new site3 --from "$W" --opt db=pg --yes 2>&1); rc=$?
expect_has "db=pg: lists the choices" "$out" "db must be one of sqlite, memory"
[ $rc -ne 0 ] && [ ! -e site3 ] && ok "db=pg: fails, writes nothing" || bad "db=pg: fails, writes nothing" "$out"
out=$("$D" . new site3 --from "$W" --opt prot=1 --yes 2>&1)
expect_has "prot=1: did you mean" "$out" "did you mean port?"
out=$("$D" . new site4 --from "$W" --dry-run --yes 2>&1); rc=$?
[ $rc -eq 0 ] && [ ! -e site4 ] && ok "--dry-run writes nothing" || bad "--dry-run writes nothing" "$out"
expect_has "--dry-run says what it would do" "$out" "Would create site4/src/main.mettle, site4/src/routes.mettle, site4/static/"
out=$("$D" . new site --from "$W" --yes 2>&1); rc=$?
expect_has "new into a non-empty dir needs --force" "$out" "site already exists and is not empty"

out=$("$D" . new site5 --from "$W" < /dev/null 2>&1)
expect_no "stdin not a terminal: no prompt" "$out" "[8080]"
file_has "stdin not a terminal: defaults" site5/src/routes.mettle 'return "8080";'

# mi_file writes its dst with its text; mi_line fills variables
F="$T/filefw-$v"
rm -rf "$F"; cp -r "$W" "$F"
sed -i 's|^  mi_dir("static");$|  mi_file("conf/port.txt", "port @@port@@\\n");\n  mi_line("// port @@port@@");|' "$F/init.rules"
out=$("$D" . new fsite --from "$F" --opt port=9000 --yes 2>&1)
file_has "mi_file: the file at dst" fsite/conf/port.txt "port 9000"
[ ! -e "fsite/port 9000" ] && ok "mi_file: no file named after the text" || bad "mi_file: no file named after the text" "$(ls fsite)"
file_has "mi_line fills variables" fsite/mbuild.mettle "  // port 9000"

cd site || exit 1
echo "// mine" > src/routes.mettle
out=$("$D" . init --from "$W" --yes 2>&1); rc=$?
expect_line "init --from: skips src/main.mettle" "$out" "        skip src/main.mettle (exists; --force overwrites)"
expect_line "init --from: skips src/routes.mettle" "$out" "        skip src/routes.mettle (exists; --force overwrites)"
expect_has "init --from: keeps the existing command" "$out" "already has command serve"
file_has "init --from: file untouched" src/routes.mettle "// mine"
n=$(grep -c 'mb_dep("sqlite"' mbuild.mettle)
[ "$n" = 1 ] && ok "init --from: dependency not added twice" || bad "init --from: dependency not added twice" "$(cat mbuild.mettle)"
n=$(grep -c 'mb_set("optimize", "full");' mbuild.mettle)
[ "$n" = 1 ] && ok "init --from: setting not added twice" || bad "init --from: setting not added twice" "$(cat mbuild.mettle)"
out=$("$D" . init --from "$W" --opt port=7000 --yes --force 2>&1); rc=$?
file_has "init --from --force: rewrites files" src/routes.mettle 'return "7000";'
file_has "init --from --force: replaces the command" mbuild.mettle 'return mb_mbuild("run -- --port 7000");'
n=$(grep -c 'fn cmd_serve' mbuild.mettle)
[ "$n" = 1 ] && ok "init --from --force: one cmd_serve" || bad "init --from --force: one cmd_serve" "$(cat mbuild.mettle)"
cd "$P" || exit 1

mkdir -p bare
cd bare || exit 1
out=$("$D" . init --from "$W" --yes 2>&1); rc=$?
expect_line "init --from without mbuild.mettle runs plain init" "$out" "     Created mbuild.mettle (package \`bare\`)"
file_has "plain init keeps the example command" mbuild.mettle "cmd_hello"
file_has "then applies the plan" mbuild.mettle 'mb_dep("sqlite", "v1.2.0");'
file_has "plain init: .gitignore" .gitignore "/mbuild.local.mettle"
cd "$P" || exit 1
mkdir -p legacy
printf '[package]\nname = "legacy"\n' > legacy/mbuild.toml
cd legacy || exit 1
out=$("$D" . init --from "$W" --yes 2>&1); rc=$?
expect_line "init --from with only mbuild.toml" "$out" "error: mbuild.toml is no longer read; write mbuild.mettle (mbuild init)"
[ ! -e mbuild.mettle ] && ok "mbuild.toml only: nothing written" || bad "mbuild.toml only: nothing written"
cd "$P" || exit 1

B1="$T/bad-var-$v"
cp -r "$W" "$B1"
printf 'export fn routes_port() -> string {\n  return "@@nope@@";\n}\n' > "$B1/templates/routes.mettle.tmpl"
out=$("$D" . new site6 --from "$B1" --yes 2>&1); rc=$?
expect_has "unknown variable: template and line" "$out" "templates/routes.mettle.tmpl:2: unknown variable @@nope@@"
[ $rc -ne 0 ] && [ ! -e site6 ] && ok "unknown variable: nothing written" || bad "unknown variable: nothing written"

B2="$T/bad-io-$v"
cp -r "$W" "$B2"
mkdir -p "$B2/src"
printf '// helpers\n\nextern fn fopen(p: cstring, m: cstring) -> cstring;\nexport fn h() -> int32 {\n  return 1;\n}\n' > "$B2/src/helpers.mettle"
sed -i 's|^import "mbuild/init";|import "mbuild/init";\nimport "src/helpers.mettle";|' "$B2/init.rules"
out=$("$D" . new site7 --from "$B2" --yes -v 2>&1); rc=$?
expect_has "extern fn: the 16.2 refusal" "$out" "error: webfw (path): init.rules may only describe a plan: src/helpers.mettle:3 declares extern fn fopen"
expect_no "extern fn: no compiler run" "$out" "--build"
if ls "$MBUILD_HOME"/init/path-*/driver 2>/dev/null | grep -q .; then
  for d in "$MBUILD_HOME"/init/path-*; do
    if grep -q "$B2" "$d/driver.mettle" 2>/dev/null && [ -e "$d/driver" ]; then bad "extern fn: no driver built"; fi
  done
fi
B3="$T/bad-sys-$v"
cp -r "$W" "$B3"
printf 'fn options() {\n  syscall(60, 0);\n}\n' > "$B3/opts.mettle"
sed -i 's|^import "mbuild/init";|import "mbuild/init";\nimport "opts.mettle";|; /^fn options() {/,/^}/d' "$B3/init.rules"
out=$("$D" . new site8 --from "$B3" --yes 2>&1)
expect_has "syscall: refused" "$out" "opts.mettle:2 uses syscall"
B4="$T/bad-std-$v"
cp -r "$W" "$B4"
sed -i 's|^import "mbuild/init";|import "mbuild/init";\nimport "std/io";|' "$B4/init.rules"
out=$("$D" . new site9 --from "$B4" --yes 2>&1)
expect_has "std/io: refused" "$out" "init.rules may only describe a plan"

out=$("$D" . check "$W" 2>&1)
expect_eq_ok=$(printf '%s' "$out")
[ "$expect_eq_ok" = ok ] && ok "ini_check_package: webfw is fine" || bad "ini_check_package: webfw is fine" "$out"
B5="$T/no-agent-$v"
cp -r "$W" "$B5"
rm "$B5/AGENT.rules"
out=$("$D" . check "$B5" 2>&1)
expect_line "ini_check_package: no AGENT.rules" "$out" "webfw cannot be published without AGENT.rules (mbuild init --package writes one)"
out=$("$D" . check "$B1" 2>&1)
expect_has "ini_check_package: unknown variable" "$out" "unknown variable @@nope@@"

mkdir -p pk
out=$("$D" pk scaffold pk 2>&1)
expect_line "scaffold: AGENT.rules" "$out" "     Created AGENT.rules"
expect_line "scaffold: init.rules" "$out" "     Created init.rules"
expect_line "scaffold: template" "$out" "     Created templates/main.mettle.tmpl"
out=$("$D" . check pk 2>&1)
[ "$out" = ok ] && ok "scaffolded package passes the check" || bad "scaffolded package passes the check" "$out"
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("pk", "0.1.0");\n}\n' > pk/mbuild.mettle
out=$("$D" . new fromscaffold --from ./pk --yes 2>&1)
file_has "new from the scaffold" fromscaffold/src/main.mettle "Hello from fromscaffold, built on pk 0.1.0!"

# Agents, with a hand-made DepState: textfmt (direct) -> strutil.
A="$T/agents-$v"
mkdir -p "$A/deps"
cp -r "$SRC/textfmt-v0.1.0" "$A/deps/textfmt"
cp -r "$SRC/strutil-v1.1.0" "$A/deps/strutil"
mkdir -p "$T/widgets-$v"
printf '# widgets\n' > "$T/widgets-$v/AGENT.rules"
printf '[package]\nname = "app"\nversion = "0.1.0"\n[dependencies]\ntextfmt = "v0.1.0"\nwidgets = { path = "../widgets-%s" }\n' "$v" > "$A/manifest.toml"
printf '# app\n\nmy notes\n' > "$A/AGENT.rules"
MODS="textfmt:v0.1.0:deps/textfmt strutil:v1.1.0:deps/strutil widgets::$T/widgets-$v"
out=$("$D" "$A" refresh $MODS 2>&1)
expect_line "refresh: Updated" "$out" "     Updated AGENT.rules"
want="# app

my notes

# >>> mbuild: AGENT.rules of this project's dependencies (generated)
# read a dependency's file before using it
# textfmt v0.1.0: deps/textfmt/AGENT.rules
# widgets (path): ../widgets-$v/AGENT.rules
# <<< mbuild"
got=$(cat "$A/AGENT.rules")
[ "$got" = "$want" ] && ok "refresh: block lists direct dependencies, user text kept" || bad "refresh: block lists direct dependencies, user text kept" "$got"
out=$("$D" "$A" refresh $MODS 2>&1)
expect_line "refresh again: unchanged" "$out" "changed=0"
out=$("$D" "$A" strip "$A/AGENT.rules" 2>&1)
[ "$out" = "$(printf '# app\n\nmy notes')" ] && ok "strip of the written file" || bad "strip of the written file" "$out"
out=$("$D" "$A" agents $MODS 2>&1)
expect_line "agents: textfmt" "$out" "== textfmt v0.1.0 (deps/textfmt/AGENT.rules)"
expect_no "agents: not strutil" "$out" "== strutil"
out=$("$D" "$A" agents --all $MODS 2>&1)
expect_line "agents --all: strutil" "$out" "== strutil v1.1.0 (deps/strutil/AGENT.rules)"
expect_has "agents --all: its text" "$out" "Every function is pure."
out=$("$D" "$A" agents strutil $MODS 2>&1)
expect_line "agents NAME" "$out" "== strutil v1.1.0 (deps/strutil/AGENT.rules)"
A2="$T/agents-off-$v"
mkdir -p "$A2"
printf '[package]\nname = "app"\nversion = "0.1.0"\n[build]\nagents = false\n[dependencies]\ntextfmt = "v0.1.0"\n' > "$A2/manifest.toml"
out=$("$D" "$A2" refresh "textfmt:v0.1.0:$A/deps/textfmt" 2>&1)
[ ! -e "$A2/AGENT.rules" ] && ok "agents = false: no file" || bad "agents = false: no file" "$out"
A3="$T/agents-none-$v"
mkdir -p "$A3"
printf '[package]\nname = "app"\nversion = "0.1.0"\n[dependencies]\nstrutil = "v1.1.0"\n' > "$A3/manifest.toml"
mkdir -p "$A3/deps/strutil"
out=$("$D" "$A3" refresh "strutil:v1.1.0:deps/strutil" 2>&1)
[ ! -e "$A3/AGENT.rules" ] && ok "no rules among dependencies: no file" || bad "no rules among dependencies: no file" "$out"
done

# --- part 2: registry and CLI -------------------------------------------------

echo "== part 2: registry"
D="$DRV/init_driver.debug"
rm -rf "$MBUILD_HOME"
P="$T/p2"
mkdir -p "$P"
cd "$P" || exit 1
out=$("$D" . new rsite --from webfw@v1.0.0 --opt port=9000 --yes 2>&1); rc=$?
expect_line "registry: mbuild.mettle line" "$out" "     Created rsite/mbuild.mettle (package \`rsite\`, depends on webfw v1.0.0, sqlite v1.2.0)"
file_has "registry: mb_dep webfw" rsite/mbuild.mettle 'mb_dep("webfw", "v1.0.0");'
[ -f "$MBUILD_HOME/init/webfw@v1.0.0/init.rules" ] && ok "registry: extracted into the init cache" || bad "registry: extracted into the init cache" "$out"
out=$("$D" . new rsite2 --from webfw --yes 2>&1)
file_has "registry: newest version" rsite2/mbuild.mettle 'mb_dep("webfw", "v1.0.0");'

echo "== part 2: CLI"
MB="$T/mbuild"
if ! "$METTLE" --build "$here/src/main.mettle" -o "$MB" > "$T/mbuild.log" 2>&1; then
  bad "mbuild builds" "$(cat "$T/mbuild.log")"
else
  # a fresh cache, so the transcript has its Fetching line (14.3)
  rm -rf "$MBUILD_HOME"
  out=$("$MB" new site --from webfw --opt port=9000 --yes 2>&1); rc=$?
  expect_line "cli new: mbuild.mettle line" "$out" "     Created site/mbuild.mettle (package \`site\`, depends on webfw v1.0.0, sqlite v1.2.0)"
  expect_line "cli new: files line" "$out" "     Created site/src/main.mettle, site/src/routes.mettle, site/static/"
  expect_line "cli new: command line" "$out" "     Command serve: run the dev server on port 9000"
  expect_line "cli new: next line" "$out" "  next: mbuild serve, then open http://localhost:9000"
  expect_has "cli new: fetch line" "$out" "Fetching webfw v1.0.0 (default)"
  file_has "cli new: routes" site/src/routes.mettle 'return "9000";'
  file_has "cli new: mbuild version" site/src/main.mettle "(mbuild $("$MB" version | cut -d' ' -f2))"
  cd site || exit 1
  out=$("$MB" run 2>&1); rc=$?
  [ $rc -eq 0 ] && ok "cli: mbuild run builds" || bad "cli: mbuild run builds" "$out"
  expect_has "cli: the program runs" "$out" "site serves on port 9000"
  out=$("$MB" init --from webfw --yes 2>&1)
  expect_has "cli init --from: skips" "$out" "skip src/main.mettle (exists; --force overwrites)"
  file_has "cli: AGENT.rules lists webfw" AGENT.rules "# webfw v1.0.0: .mbuild/deps/webfw/AGENT.rules"
  cd "$P" || exit 1

  mkdir -p tapp/src
  cat > tapp/mbuild.mettle <<'EOF'
import "mbuild/api";

fn project() {
mb_package("tapp", "0.1.0");
mb_dep("textfmt", "v0.1.0");
}
EOF
  printf 'import "std/io";\nimport "textfmt/textfmt";\n\nfn main() -> int32 {\n  print(tf_banner("x"));\n  return 0;\n}\n' > tapp/src/main.mettle
  printf '# tapp\n' > tapp/AGENT.rules
  cd tapp || exit 1
  out=$("$MB" agents 2>&1)
  file_has "cli agents: block lists textfmt" AGENT.rules "# textfmt v0.1.0: .mbuild/deps/textfmt/AGENT.rules"
  file_lacks "cli agents: not strutil" AGENT.rules "# strutil"
  file_has "cli agents: user text kept" AGENT.rules "# tapp"
  out=$("$MB" agents --all 2>&1)
  expect_line "cli agents --all: textfmt" "$out" "== textfmt v0.1.0 (.mbuild/deps/textfmt/AGENT.rules)"
  expect_line "cli agents --all: strutil" "$out" "== strutil v1.1.0 (.mbuild/deps/strutil/AGENT.rules)"
  cd "$P" || exit 1
  mkdir -p toff/src
  sed 's/mb_dep("textfmt", "v0.1.0");/mb_dep("textfmt", "v0.1.0");\n  mb_agents(false);/' tapp/mbuild.mettle > toff/mbuild.mettle
  cp tapp/src/main.mettle toff/src/
  cd toff || exit 1
  out=$("$MB" build 2>&1)
  [ ! -e AGENT.rules ] && ok "cli mb_agents(false): no file" || bad "cli mb_agents(false): no file" "$out"
  cd "$P" || exit 1

  cp -r "$W" pub
  rm pub/AGENT.rules
  # a new version: an indexed one stops publish earlier (14.7 step 2)
  sed -i 's/mb_package("webfw", "v1.0.0");/mb_package("webfw", "v1.0.1");/' pub/mbuild.mettle
  cd pub || exit 1
  out=$("$MB" publish --to "$REG" --dry-run 2>&1)
  expect_has "cli publish without AGENT.rules" "$out" "error: webfw cannot be published without AGENT.rules (mbuild init --package writes one)"
  cd "$P" || exit 1
fi

echo
echo "init: $pass passed, $failn failed"
[ $failn -eq 0 ]
