#!/bin/sh
# riscv.sh: the RISC-V targets end to end (build, outputs, settings, run and test under emulators), mbuild built debug and --release.
#   METTLE=dev-compiler sh tests/e2e/riscv.sh   (scratch: $MBTEST_TMP)

set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
METTLE="${METTLE:-$here/../Mettle/bin/mettle}"
S="${MBTEST_TMP:-/tmp/mbuild-test-${USER:-me}/riscv}"
rm -rf "$S"
mkdir -p "$S"
export LC_ALL=C NO_COLOR=1 METTLE
unset MBUILD_COLOR MBUILD_RVSIM
export MBUILD_HOME="$S/home"
export MBUILD_REGISTRY="$S/reg"

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -30; }
check() { name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$S/last.out" 2>/dev/null)"; fi; }
has() { grep -qF -- "$1" "$S/last.out"; }
code_is() { [ "$(cat "$S/last.code")" = "$1" ]; }
mb() { "$MB" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }
# riscv_elf FILE BYTE: an ELF for RISC-V (e_machine 0xf3) of class BYTE (01 = 32-bit, 02 = 64-bit)
riscv_elf() { [ "$(od -An -tx1 -j4 -N1 "$1" | tr -d ' ')" = "$2" ] && [ "$(od -An -tx1 -j18 -N1 "$1" | tr -d ' ')" = f3 ]; }

# the emulators, as mbuild finds them
qdir="${MBUILD_QEMU_USER_DIR:-}"
if [ -z "$qdir" ]; then
  if [ -x "$HOME/.local/opt/qemu-user/bin/qemu-riscv64" ]; then qdir="$HOME/.local/opt/qemu-user/bin"
  elif command -v qemu-riscv64 >/dev/null 2>&1; then qdir="$(dirname "$(command -v qemu-riscv64)")"; fi
fi
have_user=0; [ -n "$qdir" ] && [ -x "$qdir/qemu-riscv64" ] && [ -x "$qdir/qemu-riscv32" ] && have_user=1
[ $have_user = 1 ] && export MBUILD_QEMU_USER_DIR="$qdir"
have_sys=0; command -v qemu-system-riscv32 >/dev/null 2>&1 && command -v qemu-system-riscv64 >/dev/null 2>&1 && have_sys=1
have_rvsim=0; command -v gcc >/dev/null 2>&1 && [ -f "$(dirname "$(dirname "$(realpath "$METTLE")")")/tools/riscv-sim/rvsim.c" ] && have_rvsim=1
[ $have_user = 1 ] || echo "note: qemu-user runs skipped (no qemu-riscv64 and qemu-riscv32)"
[ $have_sys = 1 ] || echo "note: qemu-virt runs skipped (no qemu-system-riscv32 and qemu-system-riscv64)"
[ $have_rvsim = 1 ] || echo "note: pico2 runs skipped (no gcc, or no tools/riscv-sim/rvsim.c beside the compiler)"

for mode in ${MBTEST_MODES:-debug release}; do
flag=""
[ $mode = release ] && flag="--release"
echo "== mbuild ($mode)"
sh "$here/tools/mcompile.sh" $flag "$here/src/main.mettle" -o "$S/mbuild-$mode" >"$S/build-$mode.log" 2>&1 || { cat "$S/build-$mode.log"; exit 1; }
MB="$S/mbuild-$mode"
W="$S/$mode"

# --- hello for every target
mkdir -p "$W/hello/src" && cd "$W/hello"
cat > mbuild.mettle <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("hello", "0.1.0");
  mb_bin("hello", "src/main.mettle");
  mb_bin("spin", "src/spin.mettle");
  mb_test_bin("pass", "tests/pass.mettle");
  mb_test_bin("fail", "tests/fail.mettle");
  mb_profile("debug");
  mb_on("riscv32-none");
  mb_set("board", "qemu-virt");
  mb_on("riscv64-none");
  mb_set("board", "qemu-virt");
  mb_set("outputs", "bin, hex");
  mb_on("riscv64-linux");
  mb_set("isa", "rv64gc");
  mb_set("abi", "lp64d");
  mb_on("");
}

// out: mb_out of hello on riscv32-none
fn cmd_out(a: MbArgs*) -> int32 {
  mb_say(mb_out("hello", "riscv32-none", "debug"));
  return 0;
}
EOF
printf 'import "std/io";\nfn main() -> int32 {\n  print("Hello from hello!\\n");\n  return 3;\n}\n' > src/main.mettle
printf 'import "std/io";\nfn main() -> int32 {\n  print("spinning\\n");\n  var i: int64 = 0;\n  while (true) { i = i + 1; }\n  return 0;\n}\n' > src/spin.mettle
mkdir -p tests
printf 'fn main() -> int32 { return 0; }\n' > tests/pass.mettle
printf 'import "std/io";\nfn main() -> int32 { print("failing\\n"); return 2; }\n' > tests/fail.mettle

mb build hello -t riscv64-linux,riscv32-linux
check "build riscv64-linux and riscv32-linux" sh -c 'riscv_elf() { [ "$(od -An -tx1 -j4 -N1 "$1" | tr -d " ")" = "$2" ] && [ "$(od -An -tx1 -j18 -N1 "$1" | tr -d " ")" = f3 ]; }; riscv_elf build/riscv64-linux/debug/hello 02 && riscv_elf build/riscv32-linux/debug/hello 01'
check "no objects left beside them" sh -c '! ls build/riscv64-linux/debug/*.o build/riscv32-linux/debug/*.o 2>/dev/null'
mb -v build hello -t riscv64-linux --force
check "isa and abi per target" has "--isa rv64gc --abi lp64d"
check "the compile names the target" has "--target riscv64-linux"
mb -v build hello -t riscv32-linux --force
check "riscv32-linux: no -s, no riscv64-linux settings" sh -c 'l=$(grep -F -- "--target riscv32-linux" "$0/last.out"); [ -n "$l" ] && ! printf "%s" "$l" | grep -q -- " -s \| --isa"' "$S"
mb build hello -t riscv32-none
check "riscv32-none: bin and elf by default" sh -c '[ -s build/riscv32-none/debug/hello.bin ] && [ -s build/riscv32-none/debug/hello.elf ] && [ ! -e build/riscv32-none/debug/hello.hex ]'
check "the elf is RISC-V" riscv_elf build/riscv32-none/debug/hello.elf 01
mb build hello -t riscv64-none
check "riscv64-none: outputs bin, hex" sh -c '[ -s build/riscv64-none/debug/hello.bin ] && head -c1 build/riscv64-none/debug/hello.hex | grep -q ":" && [ ! -e build/riscv64-none/debug/hello.elf ]'
mb build hello -t riscv64-none
check "fresh the second time" has "Fresh hello (riscv64-none, debug)"
mb check -t riscv32-none,riscv64-linux
check "check for board and linux targets" sh -c 'grep -qF "Checking hello (riscv32-none)" "$0/last.out" && grep -qF "Checking hello (riscv64-linux)" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
mb out
check "mb_out names the image" has "$W/hello/build/riscv32-none/debug/hello.bin"

if [ $have_user = 1 ]; then
  mb run hello -t riscv64-linux
  check "run -t riscv64-linux" sh -c 'grep -qF "Running build/riscv64-linux/debug/hello (qemu-riscv64)" "$0/last.out" && grep -qF "Hello from hello!" "$0/last.out" && [ "$(cat "$0/last.code")" = 3 ]' "$S"
  mb run hello -t riscv32-linux
  check "run -t riscv32-linux" sh -c 'grep -qF "(qemu-riscv32)" "$0/last.out" && grep -qF "Hello from hello!" "$0/last.out" && [ "$(cat "$0/last.code")" = 3 ]' "$S"
  mb run spin -t riscv64-linux --timeout 1
  check "--timeout stops it" sh -c 'grep -qF "spinning" "$0/last.out" && grep -qF "error: build/riscv64-linux/debug/spin was stopped after 1.0s (--timeout 1)" "$0/last.out" && [ "$(cat "$0/last.code")" = 124 ]' "$S"
  mb test -t riscv64-linux
  check "test programs under qemu-riscv64" sh -c 'grep -q "^ok .*pass (tests/pass.mettle)" "$0/last.out" && grep -qF "failing" "$0/last.out" && grep -qF "FAILED fail (tests/fail.mettle) (exit 2)" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
  MBUILD_QEMU_USER_DIR="$W" mb run hello -t riscv64-linux
  check "MBUILD_QEMU_USER_DIR without qemu" has "MBUILD_QEMU_USER_DIR=$W has no qemu-riscv64"
fi
mb run hello -t riscv64-linux --timeout soon
check "--timeout takes seconds" sh -c 'grep -qF "error: --timeout needs a number of seconds, not \`soon\`" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"

if [ $have_sys = 1 ]; then
  mb run hello -t riscv32-none
  check "run -t riscv32-none on qemu-virt" sh -c 'grep -qF "Running build/riscv32-none/debug/hello.bin (qemu-system-riscv32)" "$0/last.out" && grep -qF "Hello from hello!" "$0/last.out" && [ "$(cat "$0/last.code")" = 3 ]' "$S"
  mb run hello -t riscv64-none
  check "run -t riscv64-none on qemu-virt" sh -c 'grep -qF "(qemu-system-riscv64)" "$0/last.out" && grep -qF "Hello from hello!" "$0/last.out" && [ "$(cat "$0/last.code")" = 3 ]' "$S"
  mb test -t riscv32-none pass
  check "a test program on qemu-virt" sh -c 'grep -q "^ok .*pass" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
fi

# --- settings that do not fit
mkdir -p "$W/bad/src" && cd "$W/bad"
printf 'fn main() -> int32 { return 0; }\n' > src/main.mettle
bad_proj() { printf 'import "mbuild/api";\nfn project() {\n  mb_package("bad", "0.1.0");\n  mb_profile("debug");\n%s\n}\n' "$1" > mbuild.mettle; }
bad_proj ''
mb build -t riscv32-none
check "a board image needs a board" sh -c 'grep -qF "error: bin bad: a riscv32-none image needs a board (the compiler'"'"'s boards: esp32c3, esp32c6, esp32h2, esp32p4, pico2, qemu-virt, sifive-e)" "$0/last.out" && [ "$(cat "$0/last.code")" = 1 ]' "$S"
bad_proj '  mb_set("board", "qemu-virt");'
mb build -t linux
check "board on linux" has 'error: bin bad: board = "qemu-virt" is for a board image (riscv32-none or riscv64-none), and this is "linux"; set it after mb_on("riscv32-none") in a profile, or for that bin only'
bad_proj '  mb_on("riscv32-none");
  mb_set("board", "qemu-vrit");'
mb build -t riscv32-none
check "a board the compiler lacks" sh -c 'grep -qF "board = \"qemu-vrit\" is not a board of this compiler" "$0/last.out" && grep -qF "did you mean \`qemu-virt\`?" "$0/last.out"' "$S"
bad_proj '  mb_set("objective", "size");'
mb build -t linux
check "objective on linux" has 'error: bin bad: objective is for a RISC-V target, and this is "linux"'
bad_proj '  mb_on("riscv32-linux");
  mb_set("isa", "rv64gc");'
mb build -t riscv32-linux
check "isa of the other width" has 'error: bin bad: isa = "rv64gc" does not fit "riscv32-linux": its ISA string starts with rv32'
bad_proj '  mb_on("riscv64-none");
  mb_set("board", "qemu-virt");
  mb_set("abi", "ilp32");'
mb build -t riscv64-none
check "abi of the other width" has 'error: bin bad: abi = "ilp32" does not fit "riscv64-none"; use "lp64", "lp64f" or "lp64d"'
bad_proj '  mb_set("abi", "lp64e");'
mb build -t riscv64-linux
check "lp64e" has 'abi = "lp64e": the Mettle compiler does not support RV64E and lp64e yet'
bad_proj '  mb_on("riscv32-none");
  mb_set("board", "qemu-virt");
  mb_set("outputs", "bin, uf2");'
mb build -t riscv32-none
check "uf2 needs pico2" has 'outputs = "bin, uf2": only board = "pico2" writes UF2, and this board is "qemu-virt"'
bad_proj '  mb_on("riscv32-none");
  mb_set("board", "qemu-virt");
  mb_set("exit-on-uart", "DONE");'
mb build -t riscv32-none
check "rvsim keys need pico2" has 'exit-on-uart sets up rvsim, which runs board = "pico2" only'
bad_proj '  mb_on("riscv32-none");
  mb_set("board", "esp32c3");'
mb run -t riscv32-none
check "a board with no emulator" sh -c 'grep -qF "error: board esp32c3 has no emulator mbuild can run" "$0/last.out" && grep -qF "fn cmd_flash" "$0/last.out" && [ -s build/riscv32-none/debug/bad.bin ]' "$S"
bad_proj '  mb_bin("lib", "src/main.mettle");
  mb_bin_kind("lib", "shared", "");'
mb build -t riscv64-linux
check "no shared libraries" has "error: bin lib is a shared library, and riscv64-linux builds static executables and objects only"
mb build -t riscv8-linux
check "an unknown target lists them" has "the targets are linux, windows, riscv64-linux, riscv32-linux, riscv64-none, riscv32-none, all, host"

# --- pico2 on rvsim: every output, until-ms, exit-on-uart
mkdir -p "$W/pico/src" && cd "$W/pico"
cat > mbuild.mettle <<'EOF'
import "mbuild/api";

fn project() {
  mb_package("pico", "0.1.0");
  mb_targets("riscv32-none");
  mb_bin("pico", "src/main.mettle");
  mb_bin("quiet", "src/quiet.mettle");
  mb_profile("debug");
  mb_on("riscv32-none");
  mb_set("board", "pico2");
  mb_set("outputs", "bin, uf2, elf, hex");
  mb_set("rvsim-until-ms", "300");
  mb_on("");
  mb_for_bin("pico");
  mb_set("exit-on-uart", "DONE");
}
EOF
printf 'import "std/io";\nfn main() -> int32 {\n  pico2_init();\n  println("Hello from pico!");\n  println("DONE");\n  while (true) { }\n  return 0;\n}\n' > src/main.mettle
printf 'import "std/io";\nfn main() -> int32 {\n  pico2_init();\n  println("quiet here");\n  return 0;\n}\n' > src/quiet.mettle
mb build
check "outputs bin, uf2, elf, hex" sh -c 'd=build/riscv32-none/debug; [ -s $d/pico.bin ] && [ "$(od -An -c -N4 $d/pico.uf2 | tr -d " ")" = "UF2\\n" ] && head -c1 $d/pico.hex | grep -q ":" && [ "$(od -An -tx1 -j18 -N1 $d/pico.elf | tr -d " ")" = f3 ]'
if [ $have_rvsim = 1 ]; then
  mb run pico
  check "pico2 on rvsim, exit-on-uart" sh -c 'grep -qF "Running build/riscv32-none/debug/pico.bin (rvsim)" "$0/last.out" && grep -qF "Hello from pico!" "$0/last.out" && grep -qF "printed the --exit-on-uart string" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
  [ $mode = debug ] && check "rvsim built once, into MBUILD_HOME" sh -c 'grep -qF "Building rvsim from" "$0/last.out" && [ -x "$1/tools/rvsim" ]' "$S" "$MBUILD_HOME"
  mb run quiet
  check "pico2 until-ms" sh -c 'grep -qF "quiet here" "$0/last.out" && grep -qF "stopped at --until-ms (300.000 ms" "$0/last.out" && ! grep -qF "Building rvsim" "$0/last.out" && [ "$(cat "$0/last.code")" = 0 ]' "$S"
fi
MBUILD_RVSIM="$W/nope" mb run quiet
check "MBUILD_RVSIM missing" has "error: MBUILD_RVSIM=$W/nope does not exist"
done

echo
echo "riscv: $pass passed, $failed failed"
[ $failed = 0 ]
