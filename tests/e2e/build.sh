#!/bin/sh
# build.sh: the mbuild CLI end to end on real projects, mbuild built debug and --release.
#   METTLE=dev-compiler sh tests/e2e/build.sh   (scratch: $MBTEST_TMP)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
S="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/build}"
rm -rf "$S"
mkdir -p "$S"
export LC_ALL=C NO_COLOR=1 METTLE
unset MBUILD_COLOR
export MBUILD_HOME="$S/home"
export MBUILD_REGISTRY="$S/reg"

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -30; }
check() { name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$S/last.out" 2>/dev/null)"; fi; }
has() { grep -qF -- "$1" "$S/last.out"; }
hasnt() { ! grep -qF -- "$1" "$S/last.out"; }
code_is() { [ "$(cat "$S/last.code")" = "$1" ]; }
# mb ARGS: runs mbuild in the current directory into last.out / last.code.
mb() { "$MB" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }

# unit NAME: tests/unit/NAME.mettle built debug and --release, both runs agree
unit() { if out=$(METTLE="$METTLE" TMPDIR="$S" sh "$here/tools/mcheck.sh" "$here/tests/unit/$1.mettle" --run 2>&1); then ok "$1 ($(printf '%s\n' "$out" | sed -n 's/^\[run\] ok (.*: \(.*\))$/\1/p'))"; else bad "$1" "$out"; fi; }

# the bootstrap (mettle builds mbuild0, mbuild0 builds mbuild and mbuild-shell) runs beside the rest; checked at the end
B="$S/bootstrap"
mkdir -p "$B"
cp -r "$here/src" "$here/third_party" "$here/lib" "$here/cmd" "$here/mbuild.mettle" "$B/"
bmode=release; bflag=-r
case " ${MBTEST_MODES:-debug release} " in *" release "*) ;; *) bmode=debug; bflag="" ;; esac
( cd "$B" && sh "$here/tools/mcompile.sh" src/main.mettle -o mbuild0 && MBUILD_HOME="$S/home-bootstrap" ./mbuild0 build $bflag -t host; echo $? >"$S/boot.code" ) >"$S/boot.out" 2>&1 &
bootpid=$!
echo "== unit tests"
unit graph_test
unit scan_test

for mode in debug release; do
flag=""
[ $mode = release ] && flag="--release"
echo "== mbuild ($mode)"
sh "$here/tools/mcompile.sh" $flag "$here/src/main.mettle" -o "$S/mbuild-$mode" >"$S/build-$mode.log" 2>&1 || { cat "$S/build-$mode.log"; exit 1; }
if grep -q "warning" "$S/build-$mode.log"; then bad "zero warnings ($mode)" "$(cat "$S/build-$mode.log")"; else ok "zero warnings ($mode)"; fi
MB="$S/mbuild-$mode"
W="$S/$mode"
mkdir -p "$W"

# --- init, run, project commands (13.6, 13.10)
mkdir -p "$W/hello" && cd "$W/hello"
mb init
check "init transcript" sh -c 'grep -qF "Created mbuild.mettle (package \`hello\`)" "$0/last.out" && grep -qF "Created src/main.mettle" "$0/last.out" && grep -qF "Updated .gitignore" "$0/last.out" && grep -qF "next: mbuild run" "$0/last.out"' "$S"
check "gitignore lines" grep -qx "/mbuild.local.mettle" .gitignore
check "init writes an empty fn deps() after fn project()" sh -c '[ "$(sed -n 4,9p mbuild.mettle)" = "$(printf "fn project() {\n  mb_package(\"hello\", \"0.1.0\");\n}\n\nfn deps() {\n}")" ]'
mb run
check "run prints the greeting" has "Hello from hello!"
mb hello bob
check "hello bob" has "hello, bob, from hello"
mb help
check "help lists project commands" sh -c 'grep -qxF "this project (mbuild.mettle):" "$0/last.out" && grep -q "^  hello .*example project command" "$0/last.out"' "$S"
check "help groups the commands" sh -c 'grep -qx "build:" "$0/last.out" && grep -qx "dependencies:" "$0/last.out" && grep -qx "tools:" "$0/last.out" && grep -qF "run \`mbuild help COMMAND\` for details" "$0/last.out"' "$S"
check "help has no trailing spaces" sh -c '! grep -q " $" "$0/last.out"' "$S"
mb help hello
check "help of a project command" sh -c 'grep -q "^hello - .*example project command" "$0/last.out" && grep -qF "usage: mbuild hello [ARGS...]" "$0/last.out" && grep -q "^From: mbuild.mettle:[0-9]* (fn cmd_hello)" "$0/last.out"' "$S"
mb help biuld
check "help of an unknown command" sh -c '[ "$(cat "$0/last.code")" = 1 ] && grep -qF "error: no command named biuld" "$0/last.out" && grep -qF "help: did you mean build?" "$0/last.out" && grep -qF "help: run \`mbuild help\` for the list" "$0/last.out"' "$S"
mb helo
check "helo suggests hello" has "did you mean hello?"
cat >> mbuild.mettle <<'EOF'

// build: a command that cannot run
fn cmd_build(a: MbArgs*) -> int32 {
  return 0;
}

// three: exits with 3
fn cmd_three(a: MbArgs*) -> int32 {
  return 3;
}
EOF
mb help
check "cmd_build is shadowed" has "(shadowed by the built-in build; rename cmd_build)"
mb three
check "command exit code" code_is 3

# --- shell completion: the scripts, the hidden mbuild __complete, the bash script run for real
for sh in bash zsh fish; do
  "$MB" completion $sh >"$W/comp.$sh" 2>"$W/comp.err"
  check "completion $sh: a script, nothing on stderr" sh -c '[ -s "$0" ] && [ ! -s "$1" ]' "$W/comp.$sh" "$W/comp.err"
done
check "bash completion parses" bash -n "$W/comp.bash"
if command -v zsh >/dev/null 2>&1; then check "zsh completion parses" zsh -n "$W/comp.zsh"; else echo "note: zsh syntax check skipped (no zsh)"; fi
if command -v fish >/dev/null 2>&1; then check "fish completion parses" fish -n "$W/comp.fish"; else echo "note: fish syntax check skipped (no fish)"; fi
check "zsh script is a #compdef file that also registers itself" sh -c 'head -1 "$0" | grep -qx "#compdef mbuild" && grep -qF "compdef _mbuild mbuild" "$0"' "$W/comp.zsh"
check "fish script completes mbuild" grep -qF "complete -c mbuild" "$W/comp.fish"
mb completion
check "completion needs a shell" eval 'code_is 1 && has "mbuild completion takes a shell: bash, zsh or fish"'
mb completion csh
check "completion of an unknown shell" eval 'code_is 1 && has "no completion script for csh"'
mb help completion
check "help completion has the install hint" has "mbuild completion bash > ~/.local/share/bash-completion/completions/mbuild"

mkdir -p "$W/noproj" "$W/comp/src/render" "$W/comp/cmd/tool" "$W/comp/tests"
cat > "$W/comp/mbuild.mettle" <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("comp", "0.1.0");
  mb_bin("app", "src/main.mettle");
  mb_bin("tool", "cmd/tool/main.mettle");
  mb_test_bin("smoke", "tests/smoke_test.mettle");
  mb_component("render", "src/render", "static", "gl,sw");
  mb_profile("fast");
}

fn deps() {
  mb_dep("greet", "1.0.0");
  mb_dep("textkit", "1.1.0");
}

// hello: an example command
fn cmd_hello(a: MbArgs*) -> int32 { return 0; }

// gen-docs: another one
fn cmd_gen_docs(a: MbArgs*) -> int32 { return 0; }
EOF
for f in src/main.mettle cmd/tool/main.mettle tests/smoke_test.mettle; do printf 'fn main() -> int32 {\n  return 0;\n}\n' > "$W/comp/$f"; done
# lines_are WORD...: last.out is exactly these lines
lines_are() { [ "$(cat "$S/last.out")" = "$(printf '%s\n' "$@")" ]; }
empty_out() { [ ! -s "$S/last.out" ]; }
# bcomp WORD...: what the bash script offers for the last WORD (the one being completed) after the words before it
bcomp() {
  bash -c '. "$1"; mbin=$2; shift 2; COMP_WORDS=(mbuild "$@"); COMP_CWORD=$#; COMPREPLY=(); _mbuild "$mbin" "${COMP_WORDS[COMP_CWORD]}" "${COMP_WORDS[COMP_CWORD-1]}"; [ ${#COMPREPLY[@]} -eq 0 ] || printf "%s\n" "${COMPREPLY[@]}"' _ "$W/comp.bash" "$MB" "$@" >"$S/last.out" 2>&1
}
cd "$W/noproj"
mb __complete commands
check "__complete commands outside a project: the help table's commands" sh -c '[ "$("$1" help | awk "/^run .mbuild help/ {exit} /^  [a-z]/ {print \$1}")" = "$(cat "$0/last.out")" ]' "$S" "$MB"
mb __complete targets
check "__complete targets" lines_are linux windows all host
mb __complete targets w
check "__complete takes a prefix" lines_are windows
for kind in bins tests deps components profiles; do
  mb __complete $kind
  check "__complete $kind outside a project prints nothing" eval 'code_is 0 && empty_out'
done
bcomp build ""
check "bash: bins outside a project: nothing" empty_out
bcomp -t ""
check "bash: targets outside a project" lines_are linux windows all host
bcomp ge
check "bash: commands outside a project" lines_are get
cd "$W/comp"
mb __complete commands se
check "__complete commands: a prefix" lines_are search services setup
mb __complete commands
check "__complete commands: this project's after the built-ins" sh -c 'tail -2 "$0/last.out" | tr "\n" " " | grep -qx "hello gen-docs " && grep -qx info "$0/last.out" && grep -qx completion "$0/last.out"' "$S"
mb __complete bins
check "__complete bins" lines_are app tool
mb __complete tests
check "__complete tests" lines_are smoke
mb __complete deps
check "__complete deps" lines_are greet textkit
mb __complete deps t
check "__complete deps with a prefix" lines_are textkit
mb __complete components
check "__complete components" lines_are render
mb __complete profiles
check "__complete profiles" lines_are debug release fast
mb __complete packages
check "__complete packages with no cached index prints nothing" eval 'code_is 0 && empty_out'
mb __complete nosuch
check "__complete of an unknown kind prints nothing" eval 'code_is 0 && empty_out'
cp mbuild.mettle mbuild.good
printf 'fn broken( {\n' >> mbuild.mettle
"$MB" __complete bins >"$S/last.out" 2>/dev/null
check "a project that does not load completes nothing, quietly" empty_out
"$MB" __complete commands >"$S/last.out" 2>/dev/null
check "... but its commands still come from the scan" grep -qx hello "$S/last.out"
cp mbuild.good mbuild.mettle
rm mbuild.good
bcomp se
check "bash: command names" lines_are search services setup
bcomp ""
check "bash: every command, the project's too" sh -c 'grep -qx build "$0/last.out" && grep -qx gen-docs "$0/last.out" && grep -qx hello "$0/last.out" && grep -qx completion "$0/last.out"' "$S"
bcomp build ""
check "bash: build takes bins" lines_are app tool
bcomp run a
check "bash: run takes bins" lines_are app
bcomp check ""
check "bash: check takes bins" lines_are app tool
bcomp test ""
check "bash: test takes tests" lines_are smoke
bcomp remove ""
check "bash: remove takes deps" lines_are greet textkit
bcomp why t
check "bash: why takes deps" lines_are textkit
bcomp update g
check "bash: update takes deps" lines_are greet
bcomp use ""
check "bash: use takes components" lines_are render
bcomp get zzz
check "bash: get takes packages" empty_out
bcomp help se
check "bash: help takes commands" lines_are search services setup
bcomp help fl
check "bash: help flags" lines_are flags
bcomp completion ""
check "bash: completion takes shells" lines_are bash zsh fish
bcomp toolchain us
check "bash: toolchain subcommands" lines_are use
bcomp build -p ""
check "bash: -p takes profiles" lines_are debug release fast
bcomp build --profile = f
check "bash: --profile=NAME" lines_are fast
bcomp build -t ""
check "bash: -t takes targets" lines_are linux windows all host
bcomp -t windows bu
check "bash: a flag's value is not the command" lines_are build
bcomp -j 2 run a
check "bash: ... for -j too" lines_are app
bcomp --color never te
check "bash: --color's value is not the command" lines_are test
bcomp --color ""
check "bash: --color takes auto always never" lines_are auto always never
bcomp run -
check "bash: a command's own flags and the global ones" sh -c 'grep -qx -- --no-services "$0/last.out" && grep -qx -- --release "$0/last.out" && grep -qx -- --offline "$0/last.out" && ! grep -qx -- --tree "$0/last.out"' "$S"
bcomp clean --a
check "bash: clean --all" lines_are --all
bcomp info --r
check "bash: info --readme" lines_are --readme --release
bcomp update --
check "bash: update flags" sh -c 'grep -qx -- --major "$0/last.out" && grep -qx -- --dry-run "$0/last.out"' "$S"
bcomp hello ""
check "bash: a project command's arguments are left to the shell" empty_out

# --- mbuild info for this project and its path dependencies
mkdir -p "$W/loc/lib/src" "$W/loc/app/src" "$W/loc/bare"
cat > "$W/loc/lib/mbuild.mettle" <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("lib2", "0.3.0");
  mb_meta("description", "a local library");
  mb_meta("license", "MIT");
}

fn deps() {
  mb_dep("textkit", "1.1.0");
}
EOF
printf '# lib2\n\nLocal helper library.\nTwo lines.\n\n## more\n' > "$W/loc/lib/README.md"
printf '// Doubles n.\nexport fn l2_double(n: int32) -> int32 {\n  return n * 2;\n}\n' > "$W/loc/lib/lib2.mettle"
cat > "$W/loc/app/mbuild.mettle" <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("app2", "0.1.0");
  mb_bin("app2", "src/main.mettle");
}

fn deps() {
  mb_dep_path("lib2", "../lib");
  mb_dep_path("bare", "../bare");
}
EOF
printf '/// The entry point.\nfn main() -> int32 {\n  return 0;\n}\n\n/// Entry helper.\nexport fn app_x() -> int32 {\n  return 1;\n}\n' > "$W/loc/app/src/main.mettle"
printf 'export fn bare_x() -> int32 {\n  return 2;\n}\n' > "$W/loc/bare/bare.mettle"
cd "$W/loc/app"
mb info lib2
check "info of a path dependency: version, description, README intro, license, path, deps, functions" sh -c 'grep -qx "lib2 0.3.0" "$0/last.out" && grep -qx "  a local library" "$0/last.out" && grep -qx "  Local helper library." "$0/last.out" && grep -qx "  License:       MIT" "$0/last.out" && grep -qx "  Path:          ../lib" "$0/last.out" && grep -qx "  Dependencies:  textkit 1.1.0" "$0/last.out" && grep -qx "    lib2.mettle" "$0/last.out" && grep -qx "      // Doubles n." "$0/last.out" && grep -qx "      fn l2_double(n: int32) -> int32" "$0/last.out"' "$S"
mb info .
check "info . is the project itself" sh -c 'grep -qx "app2 0.1.0" "$0/last.out" && grep -qx "  Path:          \." "$0/last.out" && grep -qx "  Dependencies:  lib2 (path ../lib), bare (path ../bare)" "$0/last.out" && grep -qx "    src/main.mettle" "$0/last.out" && grep -qx "      /// Entry helper." "$0/last.out" && grep -qx "      fn app_x() -> int32" "$0/last.out"' "$S"
mb info bare
check "info of a path dependency with no mbuild.mettle: just its functions" eval 'code_is 0 && grep -qx "bare" "$S/last.out" && has "      fn bare_x() -> int32" && hasnt "License"'
mb info lib2 --readme
check "info --readme of a path dependency" cmp -s "$S/last.out" "$W/loc/lib/README.md"
mb info . --readme
check "info . --readme of a project with none lists its functions" eval 'code_is 0 && has "app2 has no README; its exported functions:" && has "      fn app_x() -> int32"'
mb info lib2@1.0.0
check "a local package has no version to ask for" eval 'code_is 1 && has "lib2 is a local package"'
cd "$W/noproj"
mb info .
check "info . outside a project" eval 'code_is 1 && has "no project here: mbuild.mettle not found"'
cd "$W/hello"

# --- hooks (13.7)
cat >> mbuild.mettle <<'EOF'

fn hook_pre_build() -> int32 {
  mb_write_if_changed("src/version.mettle", "export const APP_VERSION: string = \"" + mb_version() + "\";\n");
  if (mb_exists("fail-hook")) { return 2; }
  return 0;
}
EOF
cat > src/main.mettle <<'EOF'
import "std/io";
import "version";

fn main() -> int32 {
  print("v" + APP_VERSION + "\n");
  return 0;
}
EOF
mb build
check "hook: first build compiles" has "Compiling hello"
mb build -v
check "hook: second build is Fresh" has "Fresh hello"
check "hook: one Running line" [ "$(grep -c "Running hook_pre_build (linux, debug)" "$S/last.out")" = 1 ]
touch fail-hook
mb build
check "failing hook stops the build" sh -c 'grep -qF "error: hook_pre_build failed (exit 2) for linux debug" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
check "failing hook: one error" [ "$(grep -c "hook_pre_build failed" "$S/last.out")" = 1 ]
mb build --no-hooks
check "--no-hooks skips it" code_is 0
rm -f fail-hook

# --- components (15)
mkdir -p "$W/comp/src/logger" && cd "$W/comp"
cat > mbuild.mettle <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("comp", "0.1.0");
  mb_bin("comp", "src/main.mettle");
  mb_bin("other", "src/other.mettle");
  mb_component("logger", "src/logger", "static", "stdout, quiet");
  mb_profile("release");
  mb_use("logger", "quiet");
}
EOF
printf 'import "std/io";\nexport fn log_line(s: string) { print("stdout: " + s + "\\n"); }\n' > src/logger/stdout.mettle
printf 'export fn log_line(s: string) { }\n' > src/logger/quiet.mettle
printf 'import "logger";\nfn main() -> int32 { log_line("hi"); return 0; }\n' > src/main.mettle
printf 'import "std/io";\nfn main() -> int32 { print("other\\n"); return 0; }\n' > src/other.mettle
mb run comp
check "static logger prints" has "stdout: hi"
mb run comp -r
check "release uses quiet" hasnt "stdout: hi"
mb run comp --use logger=quiet
check "--use logger=quiet" hasnt "stdout: hi"
mb build
mb use logger=quiet
check "use edits mbuild.local.mettle" has 'Updating mbuild.local.mettle: mb_use("logger", "quiet")'
mb build
check "use rebuilds only that bin" sh -c 'grep -qF "Compiling comp (linux, debug)" "$0/last.out" && grep -qF "Fresh other (linux, debug)" "$0/last.out"' "$S"
mb run comp
check "use logger=quiet then run" hasnt "stdout: hi"
mb components
check "components shows mbuild.local.mettle" has "mbuild.local.mettle"

# --- toolchain use --local (9): an installed toolchain becomes mb_tool in mbuild.local.mettle
TC="$MBUILD_HOME/toolchains/v0.99.0"
mkdir -p "$TC/bin" && cp "$METTLE" "$TC/bin/mettle"
mb toolchain use v0.99.0 --local
check "toolchain use --local writes mb_tool" grep -qF "mb_tool(\"mettle-linux\", \"$TC/bin/mettle\");" mbuild.local.mettle
check "toolchain use --local keeps mb_use" grep -qF 'mb_use("logger", "quiet");' mbuild.local.mettle
(unset METTLE; mb toolchain)
check "toolchain lists it" has "$TC/bin/mettle  (mb_tool(\"mettle-linux\") in mbuild.local.mettle: v0.99.0)"

# --- rules (15.8)
mkdir -p "$W/rules/src" "$W/rules/rules" && cd "$W/rules"
cat > mbuild.mettle <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("rules", "0.1.0");
  mb_rule("rules/norec.mettle");
}
EOF
printf 'fn f(n: int32) -> int32 { if (n == 0) { return 0; } return f(n - 1); }\nfn main() -> int32 { return f(3); }\n' > src/main.mettle
cat > rules/norec.mettle <<'EOF'
import "std/rule";

@rule fn no_recursion(p: Program) -> Verdict {
  for f in p.functions {
    if (f.is_recursive && f.name == "f") {
      return verdict_fail(f.site, "no recursion here");
    }
  }
  return verdict_pass();
}
EOF
mb build
check "rule fails the build" sh -c 'grep -qF "R0002" "$0/last.out" && grep -qF "could not compile rules (linux, debug)" "$0/last.out"' "$S"

# --- bin kinds (15.7)
mkdir -p "$W/kinds/src" && cd "$W/kinds"
cat > mbuild.mettle <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("kinds", "0.1.0");
  mb_bin("lib", "src/lib.mettle");
  mb_bin_kind("lib", "shared", "");
  mb_bin("boot", "src/boot.mettle");
  mb_bin_kind("boot", "flat", "x86_64-none");
  mb_for_bin("boot");
  mb_set("image-base", "0x100000");
  mb_profile("release");
  mb_set("crash-report", "false");
}
EOF
printf 'export fn add(a: int32, b: int32) -> int32 { return a + b; }\n' > src/lib.mettle
printf 'fn main() -> int32 { return 7; }\n' > src/boot.mettle
mb build
check "shared bin is an ELF shared object" sh -c 'file build/linux/debug/liblib.so | grep -q "shared object"'
check "flat bin" test -f build/x86_64-none/debug/boot.bin
mb build -r -v lib
check "crash-report = false" has "--no-crash-report"

# --- live (15.4)
mkdir -p "$W/live/src" && cd "$W/live"
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("live", "0.1.0");\n}\n' > mbuild.mettle
cat > src/main.mettle <<'EOF'
import "std/io";
import "std/thread";

fn value() -> int32 { return 1; }

fn main() -> int32 {
  var i: int32 = 0;
  while (i < 60) {
    print("{value()}\n");
    if (value() == 2 && i < 58) {
      i = 58;
    }
    quiesce;
    thread_sleep_ms(100);
    i = i + 1;
  }
  return 0;
}
EOF
# the edit once the program prints (up to 8 s)
( n=0; while ! grep -qx 1 "$S/last.out" 2>/dev/null && [ $n -lt 160 ]; do sleep 0.05; n=$((n + 1)); done; sed -i 's/return 1;/return 2;/' src/main.mettle ) &
edpid=$!
timeout 8 "$MB" live >"$S/last.out" 2>&1
wait $edpid
check "live patches" has "Patch 1"
printf '\nfn hook_post_build() -> int32 {\n  mb_say("post " + mb_built());\n  return 0;\n}\n' >> mbuild.mettle
sed -i 's/i < 60/i < 1/' src/main.mettle
timeout 8 "$MB" live >"$S/last.out" 2>&1
check "live runs the post-build hook before the program" sh -c 'grep -qx "post live" "$0/last.out" && [ "$(grep -n "^post live" "$0/last.out" | cut -d: -f1)" -lt "$(grep -n "^2$" "$0/last.out" | cut -d: -f1)" ]' "$S"

# --- publish, yank, registry (14.7)
mkdir -p "$W/pkg" && cd "$W/pkg"
"$MB" registry init "$S/reg-$mode" >"$S/last.out" 2>&1
check "registry init" test -f "$S/reg-$mode/registry.toml"
cat > mbuild.mettle <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("strx", "1.0.0");
}
EOF
printf 'export fn strx_a() -> int32 { return 1; }\nexport fn strx_b() -> int32 { return 2; }\n' > strx.mettle
mb publish --to "$S/reg-$mode"
check "publish without init.rules" has "strx cannot be published without init.rules (mbuild init --package writes one)"
rm mbuild.mettle
mb init strx --package --agent-rules
check "init --package --agent-rules: AGENT.rules" test -f AGENT.rules
check "init --package: fn deps()" grep -qx "fn deps() {" mbuild.mettle
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("strx", "1.0.0");\n}\n' > mbuild.mettle
rm -f src/main.mettle
printf '# strx\n# >>> mbuild: AGENT.rules of this project'"'"'s dependencies (generated)\n# x\n# <<< mbuild\n' >> AGENT.rules
mkdir -p libs/inner libs/kept
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("inner", "0.1.0");\n}\n' > libs/inner/mbuild.mettle
printf 'export fn inner_x() -> int32 { return 1; }\n' > libs/inner/x.mettle
printf 'export fn kept_k() -> int32 { return 1; }\n' > libs/kept/k.mettle
mb publish --to "$S/reg-$mode"
check "publish transcript" sh -c 'grep -qF "Packaging strx v1.0.0" "$0/last.out" && grep -qF "Published strx v1.0.0 to" "$0/last.out" && grep -qF "next: upload" "$0/last.out"' "$S"
mkdir -p "$S/unpack-$mode" && tar -xzf "$S/reg-$mode/pkg/strx/strx-v1.0.0.tar.gz" -C "$S/unpack-$mode"
check "published AGENT.rules has no block" sh -c '! grep -q ">>> mbuild" "$0/unpack-'$mode'/AGENT.rules"' "$S"
check "nested package left out" [ ! -e "$S/unpack-$mode/libs/inner" ]
check "plain subdir packed" [ -f "$S/unpack-$mode/libs/kept/k.mettle" ]
sed -i 's/1.0.0/1.1.0/' mbuild.mettle
printf 'export fn strx_a() -> int32 { return 1; }\n' > strx.mettle
mb publish --to "$S/reg-$mode"
check "removed export refused" has "strx_b"
MBUILD_HOME="$S/home-off-$mode" mb publish --to "$S/reg-$mode" --offline --dry-run
check "--offline into an uncached registry dir still checks the API" has "breaks the API of v1.0.0"
mb publish --to "$S/reg-$mode" --allow-breaking
check "--allow-breaking publishes" has "Published strx v1.1.0"
sed -i 's/1.1.0/1.1.1/' mbuild.mettle
printf 'export fn strx_a() -> int32 { return 1; }\nexport fn strx_c() -> int32 { return 3; }\n' > strx.mettle
mb publish --to "$S/reg-$mode" --dry-run
check "added exports in a patch: warning" has "warning: strx v1.1.1 adds exports with only a patch bump over v1.1.0"
mb -q publish --to "$S/reg-$mode"
check "-q publish publishes" [ -f "$S/reg-$mode/pkg/strx/strx-v1.1.1.tar.gz" ]
check "-q publish: no status or next line" sh -c '! grep -q "Published\|next:" "$0/last.out"' "$S"
mb yank strx@v1.1.0 --to "$S/reg-$mode"
check "yank" grep -q "v1.1.0 .*yanked" "$S/reg-$mode/index/strx"
mb yank strx@v1.1.1 --to "$S/reg-$mode"
sed -i 's/1.1.1/1.1.2/' mbuild.mettle
printf 'export fn strx_a() -> int32 { return 1; }\n' > strx.mettle
mb publish --to "$S/reg-$mode" --dry-run
check "a break against a yanked version is reported" has "strx v1.1.2 breaks the API of v1.1.1, yanked (inside line"
mb yank strx@v1.1.1 --to "$S/reg-$mode" --undo
mkdir -p "$W/user/src" && cd "$W/user"
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("user", "0.1.0");\n}\n\nfn deps() {\n  mb_dep("strx", "v1.0.0");\n}\n' > mbuild.mettle
printf 'import "std/io";\nimport "strx/strx";\nfn main() -> int32 { print("a={strx_a()}\\n"); return 0; }\n' > src/main.mettle
MBUILD_REGISTRY="$S/reg-$mode" "$MB" run >"$S/last.out" 2>&1
check "a user of the published package builds and runs" has "a=1"
MBUILD_REGISTRY="$S/reg-$mode" "$MB" outdated >"$S/last.out" 2>&1
check "yanked version not offered" hasnt "v1.1.0"

# --- a manifest warning is printed once per command
mkdir -p "$W/warn/src" && cd "$W/warn"
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("warn", "0.1.0");\n  mb_tool("cc", "gcc");\n}\n' > mbuild.mettle
printf 'fn main() -> int32 { return 0; }\n' > src/main.mettle
mb run
check "warning once" [ "$(grep -c "is machine-specific: move it to mbuild.local.mettle" "$S/last.out")" = 1 ]

# --- mbuild.toml is gone
mkdir -p "$W/old" && cd "$W/old" && printf '[package]\nname = "old"\n' > mbuild.toml
mb build
check "mbuild.toml refused" has "error: mbuild.toml is no longer read; write mbuild.mettle (mbuild init)"
mb init --from webfw
check "init --from refuses mbuild.toml" sh -c 'grep -qF "error: mbuild.toml is no longer read; write mbuild.mettle (mbuild init)" "$0/last.out" && [ ! -f mbuild.mettle ]' "$S"
mb init
check "init writes mbuild.mettle beside mbuild.toml" sh -c '[ -f mbuild.mettle ] && [ -f mbuild.toml ]'
check "init notes mbuild.toml" has "note: mbuild.toml is no longer read and can be deleted"
done

# --- everyday commands, once with the debug mbuild ------------------------------
MB="$S/mbuild-debug"
W="$S/cli"
F="$S/fx"
sh "$here/tests/fixtures/make-registry.sh" "$F" >/dev/null || exit 1
export MBUILD_REGISTRY="$F/registry"
# proj DIR: a project named after DIR with the fn project() lines on stdin
proj() {
  rm -rf "$1"; mkdir -p "$1/src"
  awk -v name="$(basename "$1")" '
    /^mb_(dep|replace)/ { d = d "  " $0 "\n"; next }
    { p = p "  " $0 "\n" }
    END { printf "import \"mbuild/api\";\n\nfn project() {\n  mb_package(\"%s\", \"0.1.0\");\n%s}\n\nfn deps() {\n%s}\n", name, p, d }' >"$1/mbuild.mettle"
}

echo "== build, run, rebuild"
proj "$W/app" </dev/null
cd "$W/app" || exit 1
cat > src/main.mettle <<'EOF'
import "std/io";
import "util";

fn main(argc: int32, argv: cstring*) -> int32 {
  print(greeting());
  print(import_str "banner.txt");
  return argc - 1;
}
EOF
printf 'export fn greeting() -> string {\n  return "greeting v1\\n";\n}\n' > src/util.mettle
echo "banner one" > src/banner.txt
mb build
check "first build" sh -c 'grep -qF "Compiling app (linux, debug)" "$0/last.out" && grep -qF "Finished" "$0/last.out"' "$S"
check "binary runs" sh -c './build/linux/debug/app | grep -q "greeting v1"'
check "embedded file used" sh -c './build/linux/debug/app | grep -q "banner one"'
check "no intermediate object left" test ! -e build/linux/debug/app.o
before=$(stat -c %y build/linux/debug/app)
mb -v build
check "second build is Fresh" has "Fresh app (linux, debug)"
check "second build does not run the compiler" hasnt "--build"
check "second build leaves the binary alone" test "$before" = "$(stat -c %y build/linux/debug/app)"
sed -i 's/greeting v1/greeting v2/' src/util.mettle
mb build
check "changing an imported file rebuilds" has "Compiling app"
check "the rebuilt binary has the change" sh -c './build/linux/debug/app | grep -q "greeting v2"'
echo "banner two" > src/banner.txt
mb build
check "changing an import_str file rebuilds" has "Compiling app"
mb build --force
check "--force rebuilds" has "Compiling app"
mb build -r
check "release build" sh -c 'grep -qF "Compiling app (linux, release)" "$0/last.out" && [ -x build/linux/release/app ]' "$S"
mb -v build --release
check "release Fresh" has "Fresh app (linux, release)"
mb run -- a b c
check "run propagates the exit code" code_is 3
check "run prints Running" has "Running build/linux/debug/app"
check "run shows the program's output" has "greeting v2"
mb biuld
check "unknown command suggests" sh -c 'grep -qF "did you mean build?" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
mb build --forse
check "unknown flag suggests" has "--force"
mb help build
check "help build" sh -c 'grep -qx "build - build the programs" "$0/last.out" && grep -qF "  usage: mbuild build" "$0/last.out" && grep -qx "  Common:" "$0/last.out" && grep -qx "Doc: docs/project.md" "$0/last.out" && ! grep -qF -- "--verbose" "$0/last.out"' "$S"
mb build -p fast
check "unknown profile fails" code_is 1
mb build -t linux,windoes
check "unknown target suggests" has "did you mean \`windows\`"

echo "== settings"
mb -v build --force
check "debug passes -s" has " -s"
mb -v build -r --force
check "release passes --release" has "--release"
check "release has no -s" sh -c '! grep -- "-o build/linux/release/app" "$0/last.out" | grep -q " -s "' "$S"
mb -v build --set safe=true
check "--set safe=true: --safe in argv" has "--safe"
check "--set safe=true: rebuilt" has "Compiling app (linux, debug)"
mb -v build --set safe=true
check "--set again: Fresh" has "Fresh app (linux, debug)"
mb -v build --flag=--explain -r --force
check "--flag after typed flags" grep -q -- "--release --explain" "$S/last.out"
mb -v build --flag --explain -r --force
check "--flag ARG form" grep -q -- "--release --explain" "$S/last.out"
proj "$W/prof" <<'EOF'
mb_profile("fast");
mb_inherits("release");
mb_set("check-overflow", "true");
EOF
cd "$W/prof" && printf 'fn main() -> int32 { return 0; }\n' > src/main.mettle
mb profiles
tr -s ' ' <"$S/last.out" >"$S/prof.txt"; cp "$S/prof.txt" "$S/last.out"
check "profiles: debug row" has "debug stack-trace -> -s"
check "profiles: release row" has "release optimize=full -> --release"
check "profiles: fast row" has "fast inherits release; check-overflow (mbuild.mettle:7) -> --release --check-overflow"
proj "$W/prof2" <<'EOF'
mb_profile("release");
mb_set("optimize", "full");
EOF
cd "$W/prof2" && printf 'fn main() -> int32 { return 0; }\n' > src/main.mettle
mb profiles
tr -s ' ' <"$S/last.out" >"$S/prof.txt"; cp "$S/prof.txt" "$S/last.out"
check "profiles: a key set like the built-in shows once" has "release optimize=full (mbuild.mettle:6) -> --release"
proj "$W/rawflag" <<'EOF'
mb_flags("--bogus-flag");
EOF
cd "$W/rawflag" && printf 'fn main() -> int32 { return 0; }\n' > src/main.mettle
mb build
check "a raw flag the compiler lacks is refused" has "error: flags: the linux compiler does not accept --bogus-flag (mbuild.mettle)"

echo "== test"
cd "$W/app" || exit 1
cat > src/calc.mettle <<'EOF'
export fn add(a: int32, b: int32) -> int32 {
  return a + b;
}

@test fn adds() -> int32 {
  if (add(2, 2) != 4) { return 1; }
  return 0;
}

@test fn adds_zero() -> int32 {
  if (add(0, 5) != 5) { return 1; }
  return 0;
}
EOF
mb test
check "test passes" sh -c 'grep -qF "ok     src/calc.mettle (2 passed)" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
mb test
check "test is cached" has "src/calc.mettle (cached)"
mb test --filter zero
check "test --filter runs a subset" has "(1 passed)"
mb test --force
check "test --force ignores the cache" hasnt "(cached)"
printf '@test fn fails() -> int32 {\n  return 7;\n}\n' > src/broken_test.mettle
mb test
check "a failing test exits 1" code_is 1
check "the failing test is named" has "FAILED src/broken_test.mettle"
check "the passing file stays cached" has "src/calc.mettle (cached)"
check "test summary" has "test result: FAILED"
mb test src/calc.mettle
check "test with an explicit file" code_is 0
rm src/broken_test.mettle

# test programs: a library with C code, tests/NAME_test.mettle with fn main
proj "$W/adder" <<'EOF'
mb_c_sources("csrc");
EOF
cd "$W/adder" || exit 1
mkdir -p csrc tests
printf 'int ad_add(int a, int b) { return a + b; }\n' > csrc/add.c
printf 'export extern fn ad_add(a: int32, b: int32) -> int32 = "ad_add";\n\n@test fn pure() -> int32 {\n  return 0;\n}\n' > src/adder.mettle
printf 'import "adder/src/adder";\nfn main() -> int32 {\n  return ad_add(2, 3) - 5;\n}\n' > tests/add_test.mettle
mb test
check "a test program calls the package's C code" sh -c 'grep -qF "ok     add (tests/add_test.mettle)" "$0/last.out" && grep -qF "ok     src/adder.mettle (1 passed)" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
check "... after the @test files, one summary" sh -c 'grep "^ok" "$0/last.out" | head -1 | grep -q adder.mettle && [ "$(grep -c "^test result: ok. 2 passed, 0 cached, 0 failed" "$0/last.out")" = 1 ]' "$S"
check "... built into .mbuild/test-bins" test -x .mbuild/test-bins/linux/debug/add
mb test
check "a passing test program is cached" has "ok     add (tests/add_test.mettle) (cached)"
check "... and not rebuilt" hasnt "Compiling test add"
printf 'import "std/io";\nfn main() -> int32 {\n  println("expected 4, got 5");\n  return 3;\n}\n' > tests/bad_test.mettle
mb test
check "a failing test program fails the run" code_is 1
check "... with its output" sh -c 'grep -qxF "expected 4, got 5" "$0/last.out" && grep -qF "FAILED bad (tests/bad_test.mettle) (exit 3)" "$0/last.out"' "$S"
mb test
check "a failing test program is never cached" has "FAILED bad"
mb test add
check "test NAME runs one test program" sh -c 'grep -qF "ok     add" "$0/last.out" && ! grep -q "bad\|adder.mettle" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
mb test nope
check "an unknown test program lists them" has "help: the test programs are: add, bad"
mb test -r add
check "test -r builds release" sh -c 'grep -qF "Compiling test add (linux, release)" "$0/last.out" && [ -x .mbuild/test-bins/linux/release/add ]' "$S"
mb build
check "build skips test programs" sh -c '! grep -q "test add\|test bad" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
rm tests/bad_test.mettle
printf '@test fn also() -> int32 {\n  return 9;\n}\n' >> tests/add_test.mettle
mb test
check "a test program's main file is no @test file" sh -c 'grep -qF "ok     add (tests/add_test.mettle)" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
sed -i 's|  mb_c_sources("csrc");|&\n  mb_test_bin("sum", "tests/add_test.mettle");|' mbuild.mettle
printf 'fn main() -> int32 {\n  return 1;\n}\n' > tests/bad_test.mettle
mb test
check "mb_test_bin replaces the detected ones" sh -c 'grep -qF "ok     sum (tests/add_test.mettle)" "$0/last.out" && ! grep -q "bad" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
cd "$W/app" || exit 1

echo "== check, clean"
mb check
check "check passes" sh -c 'grep -qF "Checking app (linux)" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
cp src/util.mettle "$S/util.keep"
printf 'export fn greeting() -> string {\n  return undefined_name;\n}\n' > src/util.mettle
mb check
check "check fails on an error" sh -c 'grep -qF "undefined_name" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
mb build
check "a build failure names the bin" has "could not compile app (linux, debug)"
cp "$S/util.keep" src/util.mettle
mb build
check "build recovers" code_is 0
mb clean
check "clean removes build/ and stamps" sh -c '[ ! -e build ] && [ ! -e .mbuild/stamps ]'
mb build
check "build after clean compiles" has "Compiling app"
mb clean --all
check "clean --all removes .mbuild" test ! -e .mbuild

echo "== several bins"
proj "$W/multi" <<'EOF'
mb_bin("multi", "src/main.mettle");
mb_bin("tool", "cmd/tool/main.mettle");
mb_bin("other", "cmd/other/main.mettle");
EOF
cd "$W/multi" || exit 1
mkdir -p cmd/tool cmd/other
for b in main tool other; do
  f=src/main.mettle; [ $b = main ] || f=cmd/$b/main.mettle
  printf 'import "std/io";\nfn main() -> int32 {\n  print("%s bin\\n");\n  return 0;\n}\n' $b > $f
done
mb build
check "three bins" sh -c '[ -x build/linux/debug/multi ] && [ -x build/linux/debug/tool ] && [ -x build/linux/debug/other ]'
mb run tool
check "run picks a bin" has "tool bin"
mb run
check "run defaults to the package's bin" has "main bin"
mb build toool
check "an unknown bin suggests" sh -c 'grep -qF "did you mean \`tool\`" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
mb build other
check "build one bin" sh -c 'grep -qF "other (linux, debug)" "$0/last.out" && ! grep -qF "tool (linux" "$0/last.out"' "$S"
printf 'fn main() -> int32 {\n  return undefined_a;\n}\n' > cmd/tool/main.mettle
printf 'fn main() -> int32 {\n  return undefined_b;\n}\n' > cmd/other/main.mettle
mb build -j 4 --force
check "parallel: two broken bins fail" code_is 1
check "parallel: both reported" sh -c 'grep -qF "could not compile other (linux, debug)" "$0/last.out" && grep -qF "could not compile tool (linux, debug)" "$0/last.out"' "$S"
a=$(grep -n "undefined_a" "$S/last.out" | head -1 | cut -d: -f1)
b=$(grep -n "undefined_b" "$S/last.out" | head -1 | cut -d: -f1)
check "parallel: output in declaration order" test "${a:-0}" -lt "${b:-0}"

echo "== zero-config, libraries"
mkdir -p "$W/zero" && cd "$W/zero" || exit 1
printf 'import "std/io";\nfn main() -> int32 {\n  print("zero config\\n");\n  return 0;\n}\n' > main.mettle
mb build
check "zero-config names the bin after the directory" has "Compiling zero"
check "zero-config wrote no project file" test ! -e mbuild.mettle
mkdir -p "$W/zero2" && cd "$W/zero2" || exit 1
printf 'import "std/io";\nfn main() -> int32 {\n  print("hello file\\n");\n  return 0;\n}\n' > hello.mettle
mb run
check "zero-config single file" has "hello file"
mkdir -p "$W/nothing" && cd "$W/nothing" || exit 1
mb build
check "outside a project: suggests mbuild init" sh -c 'grep -qF "mbuild init" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
proj "$W/mylib" </dev/null
cd "$W/mylib" || exit 1
printf 'export fn add(a: int32, b: int32) -> int32 {\n  return a + b;\n}\n' > src/lib.mettle
printf 'export fn twice(a: int32) -> int32 {\n  return a * 2;\n}\n' > helpers.mettle
printf 'import "src/lib";\n@test fn adds() -> int32 {\n  if (add(1, 2) != 3) { return 1; }\n  return 0;\n}\n' > lib_test.mettle
mb check
check "library check" sh -c 'grep -qF "Checking src/lib (linux)" "$0/last.out" && grep -qF "Checking helpers (linux)" "$0/last.out" && ! grep -qF "lib_test" "$0/last.out"' "$S"
check "library check leaves out mbuild.mettle" hasnt "Checking mbuild (linux)"
mb build
check "library build: nothing to link" has "library: nothing to link"
mb run
check "library run explains" sh -c 'grep -qF "is a library" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
mb test
check "library test" code_is 0
printf 'extern fn mbx_answer() -> int32 = "mbx_answer";\n@test fn answer() -> int32 {\n  if (mbx_answer() != 42) { return 1; }\n  return 0;\n}\n' > e_test.mettle
mb test e_test.mettle
check "a test that calls C is skipped" sh -c 'grep -qF "(0 passed, 1 skipped)" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"

echo "== prelude, nested projects, colour"
proj "$W/tflags" <<'EOF'
mb_prelude(true);
EOF
cd "$W/tflags" || exit 1
mkdir -p nested/src deep/x/build
printf 'fn main() -> int32 {\n  println("prelude main");\n  return 0;\n}\n' > src/main.mettle
printf '@test fn uses_prelude() -> int32 {\n  println("no import needed");\n  return 0;\n}\n' > src/p_test.mettle
mb test
check "test with mb_prelude(true)" has "ok     src/p_test.mettle"
mb -v test --force
check "test passes --prelude" has "--prelude"
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("nested", "0.1.0");\n}\n' > nested/mbuild.mettle
printf '@test fn nested_fails() -> int32 {\n  return 1;\n}\n' > nested/src/n_test.mettle
printf '@test fn build_fails() -> int32 {\n  return 1;\n}\n' > deep/x/build/b_test.mettle
mb test
check "test skips nested projects and build/" sh -c '[ "$(cat "$0/last.code")" = 0 ] && ! grep -q "n_test\|b_test" "$0/last.out"' "$S"
mb --color=always -v build --force
check "--color=always passes CLICOLOR_FORCE" has "CLICOLOR_FORCE=1"
mb --color never -v build --force
check "--color never passes NO_COLOR" sh -c 'grep -qF "NO_COLOR=1" "$0/last.out" && ! grep -qF "CLICOLOR_FORCE" "$0/last.out"' "$S"
LANG=C.UTF-8 LC_ALL= LC_CTYPE= mb --color always -v build --force
check "a UTF-8 locale passes METTLE_DIAG_UNICODE" has "METTLE_DIAG_UNICODE=1"
mb -v build
check "colour settings do not invalidate the build" has "Fresh tflags"
printf 'fn main() -> int32 {\n  return undefined_name;\n}\n' > src/main.mettle
mb --color always build
check "--color always: coloured diagnostics" has "$(printf '\033')[2m[E0003]"

echo "== compiler shortcuts, doctor"
mb mettle -- --version
check "mettle -- --version" has "mettle v"
mb explain E0003
check "explain E0003" sh -c 'grep -qF "E0003" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
mb version
check "version" has "mbuild 0.2.0"
mb doctor -t linux
check "doctor" sh -c 'grep -qF "host" "$0/last.out" && grep -qF "cc windows" "$0/last.out" && grep -qF "pkg-config" "$0/last.out" && grep -qF "curl" "$0/last.out"' "$S"
proj "$W/tools" </dev/null
cd "$W/tools" && printf 'fn main() -> int32 { return 0; }\n' > src/main.mettle
printf 'import "mbuild/api";\n\nfn local() {\n  mb_tool("mettle-linux", "%s");\n}\n' "$METTLE" > mbuild.local.mettle
(unset METTLE; mb doctor)
check "doctor names mbuild.local.mettle" has "mb_tool(\"mettle-linux\") in mbuild.local.mettle"
ln -s "$METTLE" "$S/mettle-link"
MBUILD_METTLE_LINUX="$S/mettle-link" mb doctor
check "the variable wins" has "MBUILD_METTLE_LINUX"

proj "$W/cmdout" </dev/null
cd "$W/cmdout" || exit 1
printf 'fn main() -> int32 { return 0; }\n' > src/main.mettle
cat >> mbuild.mettle <<'EOF'

// out: what mb_cmd_output gives
fn cmd_out(a: MbArgs*) -> int32 {
  var c: MbCmd* = mb_cmd("printf");
  mb_cmd_arg(c, "one\\ntwo\\n\\n");
  mb_say("[" + mb_cmd_output(c) + "]");
  return 0;
}
EOF
mb out
check "mb_cmd_output drops one trailing newline" sh -c 'printf "[one\ntwo\n]\n" | cmp -s - "$0"' "$S/last.out"

echo "== packages from the registry"
cp -r "$F/app" "$W/fxapp"
cd "$W/fxapp" || exit 1
mb build --locked
check "--locked: a missing package fails" code_is 1
check "--locked leaves mbuild.mettle" cmp -s mbuild.mettle "$F/app/mbuild.mettle"
mb run
check "the fixture app runs" has "vecmath! strutil v1.0.0 dot=50.0 len=5.0"
mb tidy
check "tidy adds a directly imported, already selected package" has "strutil v1.0.0"
check "tidy writes it" grep -qF 'mb_dep("strutil", "v1.0.0");' mbuild.mettle
cp src/main.mettle "$S/main.keep"
sed -i 's|strutil/strutil"|strutil/strutl"|' src/main.mettle
mb build
check "a typo'd file in a selected package" has "strutil (v1.0.0) has no file 'strutl.mettle'"
check "a typo'd file: did you mean" has "did you mean \`strutil/strutil\`"
check "a typo'd file: not a missing package" hasnt "no registry has a package"
sed -i 's|strutil/strutl"|strutil/"|' src/main.mettle
mb build
check "a directory import" sh -c 'grep -qF "package directory" "$0/last.out" && grep -qF "strutil/strutil" "$0/last.out"' "$S"
cp "$S/main.keep" src/main.mettle
mkdir -p tools/sub
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("sub", "0.1.0");\n}\n' > tools/sub/mbuild.mettle
printf 'import "zero/zero";\nfn main() -> int32 {\n  return 0;\n}\n' > tools/sub/main.mettle
sed -i 's|^import "strutil/strutil";||; s| {su_version()}||' src/main.mettle
mb tidy
check "tidy drops a package only a dependency imports" sh -c '! grep -q "\"strutil\"" mbuild.mettle'
check "tidy ignores a nested project's imports" sh -c '! grep -q "\"zero\"" mbuild.mettle'
mb build
check "build after tidy" code_is 0

echo "== fn deps()"
mkdir -p "$W/olddeps/src" && cd "$W/olddeps" || exit 1
printf 'import "mbuild/api";\n\nfn project() {\n  mb_package("olddeps", "0.1.0");\n  mb_dep("strutil", "v1.0.0");\n}\n' > mbuild.mettle
printf 'import "strutil/strutil";\nfn main() -> int32 { return 0; }\n' > src/main.mettle
mb build
check "a dep in fn project(): builds" code_is 0
check "... warns" has "warning: mbuild.mettle:5: mb_dep belongs in fn deps()"
check "... once" [ "$(grep -c 'belongs in fn deps' "$S/last.out")" = 1 ]
check "... help" has "help: mbuild tidy moves it"
mb get apilib@v1.0.0
check "get makes fn deps() after fn project()" sh -c '[ "$(sed -n 7,10p mbuild.mettle)" = "$(printf "\nfn deps() {\n  mb_dep(\"apilib\", \"v1.0.0\");\n}")" ]'
mb tidy
check "tidy: no warning" hasnt "belongs in"
check "tidy moves it" has "Moving mbuild.mettle: 1 line from fn project() into fn deps()"
check "tidy: the moved file" sh -c '[ "$(cat mbuild.mettle)" = "$(printf "import \"mbuild/api\";\n\nfn project() {\n  mb_package(\"olddeps\", \"0.1.0\");\n}\n\nfn deps() {\n  mb_dep(\"strutil\", \"v1.0.0\");\n}")" ]'
mb build
check "after the move: no warning" hasnt "warning"

echo "== update and get verify the code"
proj "$W/upd" <<'EOF'
mb_dep("apilib", "v1.0.0");
EOF
cd "$W/upd" || exit 1
cat > src/main.mettle <<'EOF'
import "std/io";
import "apilib/apilib";
fn main() -> int32 {
  var m: int32 = al_mul(2, 3);
  println("{al_add(1, 2)} {m}");
  return 0;
}
EOF
mb build
mb update
check "update: Updated" has "Updated apilib v1.0.0 -> v1.1.0"
check "update: Held" has "Held apilib v1.2.0: src/main.mettle:4: Undefined function 'al_mul'"
check "update: Summary" has "Summary 1 updated, 1 held back"
check "update: mbuild.mettle" grep -qF 'mb_dep("apilib", "v1.1.0");' mbuild.mettle
check "update: the kept edit prints once" [ "$(grep -cF 'Updating mbuild.mettle: mb_dep("apilib", "v1.1.0")' "$S/last.out")" = 1 ]
proj "$W/dry" <<'EOF'
mb_dep("apilib", "v1.0.0");
EOF
cd "$W/dry" || exit 1
printf 'import "apilib/apilib";\nfn main() -> int32 { return al_mul(1, 2) - 2; }\n' > src/main.mettle
mb build
cp mbuild.mettle "$S/dry.mettle"; cp mbuild.lock "$S/dry.lock"
mb update --dry-run
check "dry-run: Would update" has "Would update apilib v1.0.0 -> v1.2.0"
check "dry-run: API report" has "API changes from v1.0.0 to v1.2.0 (inside line v1, which should not break):"
check "dry-run: nothing written" sh -c 'cmp -s mbuild.mettle "$0/dry.mettle" && cmp -s mbuild.lock "$0/dry.lock"' "$S"
mb get apilib@v1.2.0
check "get: breaks this project" sh -c 'grep -qF "error: apilib v1.2.0 breaks this project:" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
check "get: the error" has "    src/main.mettle:2: Undefined function 'al_mul' (E0003)"
check "get: Restored" has "  Restored mbuild.mettle and mbuild.lock"
check "get: help" has "help: stay on v1.0.0 (\`mbuild get apilib@v1.0.0\`), or take it and fix the code: \`mbuild get apilib@v1.2.0 --no-verify\`"
check "get: restored" sh -c 'cmp -s mbuild.mettle "$0/dry.mettle" && cmp -s mbuild.lock "$0/dry.lock"' "$S"
mb get apilib@v1.2.0 --no-verify
check "get --no-verify takes it" grep -qF 'mb_dep("apilib", "v1.2.0");' mbuild.mettle
cp mbuild.lock "$S/dry.lock"
mb update --locked
check "update --locked refuses" sh -c 'grep -qF -- "--locked forbids it" "$0/last.out" && cmp -s mbuild.lock "$0/dry.lock"' "$S"

echo "== why, outdated, clashes, minimum Mettle"
proj "$W/why" <<'EOF'
mb_dep("vecmath", "v0.2.0");
mb_dep("strutil", "v1.0.0");
EOF
cd "$W/why" || exit 1
printf 'import "vecmath/vecmath";\nimport "strutil/strutil";\nfn main() -> int32 { return vm_one() - 1; }\n' > src/main.mettle
mb build
mb why strutil
check "why NAME" has "strutil v1.1.0 (selected: the highest of the versions required)"
check "why NAME: imported by" has "vecmath v0.2.0: vecmath.mettle:1"
mb why main vm_one
check "why A B reaches the compiler" hasnt "is not a dependency"
mb outdated
tr -s ' ' <"$S/last.out" >"$S/outd.txt"; cp "$S/outd.txt" "$S/last.out"
check "outdated: vecmath row" has "vecmath v0.2.0 - v0.3.0 (new line) mbuild.mettle"
proj "$W/clash" <<'EOF'
mb_dep("clash1", "v1.0.0");
mb_dep("clash2", "v1.0.0");
EOF
cd "$W/clash" || exit 1
printf 'import "clash1/clash1";\nimport "clash2/clash2";\nfn main() -> int32 { return clash_name(); }\n' > src/main.mettle
mb build
check "clash: fails" code_is 1
check "clash: note" has "note: \`clash_name\` is exported by both clash2 (clash2.mettle:1) and clash1 (clash1.mettle:1); plain imports share one namespace"
check "clash: help" has "help: import one of them under a name: import \"clash1/clash1\" as clash1;"
proj "$W/needy" <<'EOF'
mb_dep("needs", "v1.0.0");
EOF
cd "$W/needy" || exit 1
printf 'import "needs/needs";\nfn main() -> int32 { return needs_val() - 9; }\n' > src/main.mettle
mb build
check "needs a newer Mettle: fails" code_is 1
check "needs a newer Mettle: error" has "error: needs v1.0.0 needs Mettle v0.99.0 or newer; the linux compiler is"
check "needs: the newest supporting version" has "or require needs v0.9.0, the newest version that supports Mettle"
sed -i 's/v1.0.0/v0.9.0/' mbuild.mettle
mb build
check "needs v0.9.0 builds" code_is 0

echo "== dependency bins"
proj "$W/meosql" <<'EOF'
mb_c_sources("csrc");
mb_profile("bench");
mb_inherits("release");
EOF
cd "$W/meosql" || exit 1
mkdir -p csrc cmd/server cmd/admin
printf 'int mq_port(void) { return 5433; }\n' > csrc/port.c
printf 'export extern fn mq_port() -> int32 = "mq_port";\n' > meosql.mettle
printf 'import "std/io";\nimport "meosql/meosql";\nfn main() -> int32 {\n  println("serving on {mq_port()}");\n  return 0;\n}\n' > cmd/server/main.mettle
printf 'fn main() -> int32 {\n  return 0;\n}\n' > cmd/admin/main.mettle
proj "$W/sass" <<'EOF'
mb_dep_path("meosql", "../meosql");
mb_dep_bin("meosql", "server");
EOF
cd "$W/sass" || exit 1
printf 'import "meosql/meosql";\nfn main() -> int32 {\n  return mq_port() - 5433;\n}\n' > src/main.mettle
mb build
check "a dependency's bin is built" has "Compiling meosql/server (linux, debug)"
check "... into the project's output directory" sh -c './build/linux/debug/server | grep -qx "serving on 5433"'
check "... with the library it needs" test -f build/linux/debug/libmb_meosql.so
check "only the bins named" test ! -e build/linux/debug/admin
check "its C library compiles once" sh -c '[ "$(grep -c "Compiling meosql (C" "$0/last.out")" = 1 ] && [ ! -e .mbuild/dep-bins/meosql/cache ]' "$S"
mb build
check "an unchanged dependency bin is Fresh" has "Fresh meosql/server (linux, debug)"
check "... and its C library too" sh -c '! grep -q "Compiling meosql (C" "$0/last.out"' "$S"
printf '// edited\n' >> ../meosql/cmd/server/main.mettle
mb build
check "an edit rebuilds it" sh -c 'grep -qF "Compiling meosql/server" "$0/last.out" && grep -qF "Fresh sass" "$0/last.out"' "$S"
mb run
check "run does not start it" sh -c '[ "$(cat "$0/last.code")" = 0 ] && ! grep -q "serving on" "$0/last.out"' "$S"
mb build -r
check "the same profile: release" sh -c 'grep -qF "Compiling meosql/server (linux, release)" "$0/last.out" && [ -x build/linux/release/server ]' "$S"
cat > mbuild.mettle <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("sass", "0.1.0");
  mb_profile("bench");
  mb_inherits("release");
  mb_profile("prof");
  mb_inherits("release");
}

fn deps() {
  mb_dep_path("meosql", "../meosql");
  mb_dep_bin("meosql", "server");
}

fn hook_post_build() -> int32 {
  mb_say("post " + mb_bins());
  return 0;
}
EOF
mb build -p bench
check "a profile the dependency has" has "Compiling meosql/server (linux, bench)"
check "the post-build hook runs after it" sh -c 'tail -2 "$0/last.out" | head -1 | grep -qx "post sass"' "$S"
mb build -p prof
check "a profile it lacks: its nearest ancestor" sh -c 'grep -qF "Compiling meosql/server (linux, release)" "$0/last.out" && [ -x build/linux/prof/server ]' "$S"
sed -i 's|mb_dep_bin("meosql", "server");|mb_dep_bin("meosql", "sever");|' mbuild.mettle
mb build
check "no such bin" has 'error: mb_dep_bin("meosql", "sever"): meosql has no bin `sever`'
check "no such bin: its bins" has "help: did you mean \`server\`? meosql's bins are: admin, server"
check "no such bin: nothing compiled" hasnt "Compiling"
sed -i 's|mb_dep_bin("meosql", "sever");|mb_dep_bin("meosql", "sass");|' mbuild.mettle
mkdir -p ../meosql/cmd/sass && printf 'fn main() -> int32 {\n  return 0;\n}\n' > ../meosql/cmd/sass/main.mettle
mb build
check "a bin name the project has" has 'error: mb_dep_bin("meosql", "sass"): this project has a bin `sass` too, and both would build to the same file'
mb clean
check "clean removes their state" sh -c 'grep -qF "Removed .mbuild/dep-bins" "$0/last.out" && [ ! -e .mbuild/dep-bins ]' "$S"

echo "== bootstrap"
wait $bootpid
cp "$S/boot.out" "$S/last.out"; cp "$S/boot.code" "$S/last.code"
cd "$B" || exit 1
check "mettle builds mbuild0, mbuild0 builds mbuild" code_is 0
./build/linux/$bmode/mbuild version >"$S/last.out" 2>&1
check "the $bmode mbuild runs" has "mbuild 0.2.0"
./build/linux/$bmode/mbuild build $bflag -t host >"$S/last.out" 2>&1
check "and sees itself Fresh" sh -c 'grep -qF "Fresh mbuild (linux, '$bmode')" "$0/last.out" && grep -qF "Fresh mbuild-shell (linux, '$bmode')" "$0/last.out"' "$S"
./build/linux/$bmode/mbuild help >"$S/last.out" 2>&1
check "its project commands" sh -c 'grep -q "^  install " "$0/last.out" && grep -q "^  selfcheck " "$0/last.out" && grep -q "^  dist " "$0/last.out"' "$S"

if [ -n "${METTLE_WIN:-}" ] && [ "${SKIP_WINE:-0}" != 1 ]; then
  echo "== windows"
  export MBUILD_METTLE_WINDOWS="$METTLE_WIN"
  proj "$W/cross" </dev/null
  cd "$W/cross" || exit 1
  printf 'import "std/io";\nfn main() -> int32 {\n  print("Hello from cross!\\n");\n  return 0;\n}\n' > src/main.mettle
  mb build -t all
  check "build -t all" sh -c '[ -x build/linux/debug/cross ] && [ -f build/windows/debug/cross.exe ]'
  mb run -t windows
  check "run -t windows through wine" has "Hello from cross!"
  mb -v build -t windows -r --force
  check "windows release passes --release" has "--release"
  ( cd "$B" && wine "$METTLE_WIN" --build src/main.mettle -o mbuild.exe ) >"$S/last.out" 2>&1
  check "mbuild.exe builds" test -f "$B/mbuild.exe"
  wine "$B/mbuild.exe" build -t all >"$S/last.out" 2>&1
  check "mbuild.exe under wine sees the Linux build Fresh" has "Fresh cross (linux, debug)"
else
  echo "note: windows skipped (METTLE_WIN names no Windows dev compiler)"
fi

echo
echo "build: $pass passed, $failed failed"
[ $failed = 0 ]
