#!/bin/sh
# r2_git.sh: round-2 tests of src/git.mettle (DESIGN.md 12.21 group G) through
# tests/git_driver.mettle, against the local git fixtures (12.19).
#
#   sh tests/r2_git.sh            Linux driver (built with the head compiler)
#   sh tests/r2_git.sh --wine     also the Windows driver (v0.17.0) under wine
#   DRIVER_METTLE=path/to/mettle  build the Linux driver with another compiler
#
# Scratch space: /tmp/opencode/r2-G (MBUILD_HOME lives there; ~/.mbuild is
# never touched). Under wine, MBUILD_HOME and checkout directories are given
# in Windows form (Z:/tmp/...), MBUILD_GIT_BASE in Linux form, as in
# deps_test.sh.

set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
HEAD="${METTLE_HEAD:-$here/../Mettle/bin/mettle}"
W017="${METTLE_W017:-$HOME/.mbuild/toolchains/v0.17.0/windows/mettle.exe}"
S=/tmp/opencode/r2-G
rm -rf "$S"
mkdir -p "$S"
export WINEDEBUG=-all
export LC_ALL=C

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /' | head -40; }
check() { # name, command...
  name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name" "$(cat "$S/last.out" 2>/dev/null)"; fi
}
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
code_is() { [ "$(cat "$S/last.code")" = "$1" ]; }
out_is() { [ "$(cat "$S/last.out")" = "$1" ]; }

echo "== building the driver"
"${DRIVER_METTLE:-$HEAD}" --build "$here/tests/git_driver.mettle" -o "$S/drv" >"$S/build.log" 2>&1 || { cat "$S/build.log"; exit 1; }

echo "== fixtures"
F="$S/fx"
"$here/tests/fixtures/make-fixtures.sh" "$F" >/dev/null
if [ -f "$here/tests/fixtures/make-fixtures-r2.sh" ]; then
  sh "$here/tests/fixtures/make-fixtures-r2.sh" "$F" >/dev/null
else
  # Not there yet: take the script from DESIGN.md 12.19.
  sed -n '/^```sh$/,/^```$/p' "$here/DESIGN.md" | sed -n '/Round-2 fixtures/,$p' | sed '$d' >"$S/make-r2.sh"
  sh "$S/make-r2.sh" "$F" >/dev/null
fi
G="$F/gitbase/github.com/demo"
[ -d "$G/wrapper/.git" ] || { echo "round-2 fixtures missing"; exit 1; }
tagc() { git -C "$1" rev-parse "$2^{commit}"; }
W10=$(tagc "$G/wrapper" v1.0.0)
W11=$(tagc "$G/wrapper" v1.1.0)
C10=$(tagc "$G/clib" v1.0.0)
D10=$(tagc "$G/deep" v1.0.0)

# A copy whose wrapper v9.0.0 pins a clib commit that does not exist.
F2="$S/fx2"
mkdir -p "$F2"
cp -a "$F/gitbase" "$F2/gitbase"
B="$F2/gitbase/github.com/demo/wrapper"
git -C "$B" update-index --cacheinfo "160000,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,vendor/clib"
git -C "$B" commit -q -m "wrapper 9.0.0: unpushed clib"
git -C "$B" tag -a v9.0.0 -m "wrapper 9.0.0"

# A repository with a commit no ref reaches.
DG="$F/gitbase/dangle"
git init -q -b main "$DG"
git -C "$DG" config user.email t@t; git -C "$DG" config user.name t
echo 1 >"$DG/a"; git -C "$DG" add -A; git -C "$DG" commit -q -m one
# After the mirror is made: a commit, then the branch reset below it (a
# force-push upstream).
dangle() {
  echo "$1" >"$DG/a"; git -C "$DG" commit -q -am "$1"
  DANGLE=$(git -C "$DG" rev-parse HEAD)
  git -C "$DG" reset -q --hard HEAD~1
}

# A link to a directory holding keep.txt.
T="$S/linkt"
mkdir -p "$T/target"
echo keep >"$T/target/keep.txt"
ln -s "$T/target" "$T/link"

# suite PREFIX DRIVER... : P is the path prefix the driver needs ("" or Z:),
# H the Linux path of its MBUILD_HOME.
suite() {
  L="$1"
  if [ "$L" = "wine: " ]; then
    P="Z:"; H="$S/whome"; X="$S/wx"
    run() { MBUILD_HOME="Z:$H" MBUILD_GIT_BASE="$GB" wine "$S/drv.exe" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; tr -d '\r' <"$S/last.out" >"$S/last.tmp"; mv "$S/last.tmp" "$S/last.out"; }
  else
    P=""; H="$S/home"; X="$S/x"
    run() { MBUILD_HOME="$H" MBUILD_GIT_BASE="$GB" "$S/drv" "$@" >"$S/last.out" 2>&1; echo $? >"$S/last.code"; }
  fi
  GB="$F/gitbase"
  mkdir -p "$H" "$X"
  ln -sfn "$HOME/.mbuild/toolchains" "$H/toolchains"

  echo "== ${L}git_resolve_url"
  rcheck() { # base rel expected
    run resolve "$1" "$2"
    if [ "$(cat "$S/last.out")" = "$3" ]; then ok "${L}resolve $1 + $2"; else bad "${L}resolve $1 + $2 -> want $3" "$(cat "$S/last.out")"; fi
  }
  for base in https://github.com/o/r https://github.com/o/r/; do
    rcheck "$base" ../c.git https://github.com/o/c.git
    rcheck "$base" ./sub/d https://github.com/o/r/sub/d
    rcheck "$base" ../../x/e https://github.com/x/e
  done
  rcheck https://github.com/o/r.git ../c.git https://github.com/o/c.git
  rcheck https://github.com/o/r.git ./sub/d https://github.com/o/r.git/sub/d
  rcheck https://github.com/o/r.git ../../x/e https://github.com/x/e
  rcheck git@github.com:o/r ../c.git git@github.com:o/c.git
  rcheck git@github.com:o/r ./sub/d git@github.com:o/r/sub/d
  rcheck git@github.com:o/r ../../x/e git@github.com:x/e
  rcheck /srv/git/o/r ../c.git /srv/git/o/c.git
  rcheck /srv/git/o/r ./sub/d /srv/git/o/r/sub/d
  rcheck /srv/git/o/r ../../x/e /srv/git/x/e
  rcheck https://github.com/o/r ../../../z "<empty>"
  rcheck git@github.com:o/r ../../../z "<empty>"
  rcheck https://github.com/o/r https://elsewhere/x https://elsewhere/x

  echo "== ${L}git_url_mirror_dir, git_failure_kind"
  run urlmirror https://github.com/o/clib.git
  check "${L}url mirror under git/sub, leaf without .git" grep -qE "^${P}$H/git/sub/clib@[0-9a-f]{12}\.git\$" "$S/last.out"
  kcheck() { run kind "$1"; if out_is "$2"; then ok "${L}kind $2: $1"; else bad "${L}kind $1 -> want $2" "$(cat "$S/last.out")"; fi; }
  kcheck "fatal: unable to access 'https://x/': Could not resolve host: x" network
  kcheck "ssh: connect to host x port 22: Connection refused" network
  kcheck "remote: Repository not found." gone
  kcheck "fatal: repository 'https://github.com/a/b/' not found" gone
  kcheck "fatal: could not read Username for 'https://github.com': terminal prompts disabled" auth
  kcheck "git@github.com: Permission denied (publickey)." auth
  kcheck "fatal: something else broke" other

  echo "== ${L}git_submodules"
  run mirror github.com/demo/wrapper
  check "${L}wrapper mirror" code_is 0
  WM=$(sed -n 's/^MIRROR //p' "$S/last.out")
  run subs "$WM" "$W10"
  check "${L}wrapper v1.0.0 has one submodule" [ "$(grep -c '^SUB ' "$S/last.out")" = 1 ]
  check "${L}  vendor/clib ../clib <clib v1.0.0>" has "$S/last.out" "SUB vendor/clib ../clib $C10"
  check "${L}  ok" has "$S/last.out" "ok 1"
  run mirror github.com/demo/strutil
  SM=$(sed -n 's/^MIRROR //p' "$S/last.out")
  run subs "$SM" "$(tagc "$G/strutil" v1.0.0)"
  check "${L}strutil: ok, no submodules" out_is "ok 1"
  run subject "$WM" v1.1.0
  check "${L}git_tag_subject" out_is "subject wrapper 1.1.0 (clib 1.1.0 = 43)"

  echo "== ${L}git_checkout_tree"
  D="$X/wrapper"
  run tree github.com/demo/wrapper v1.0.0 "$P$D"
  check "${L}tree wrapper v1.0.0 exits 0" code_is 0
  check "${L}  vendor/clib/clib.c" [ -f "$D/vendor/clib/clib.c" ]
  check "${L}  deep.h two levels down" [ -f "$D/vendor/clib/third_party/deep/include/deep.h" ]
  check "${L}  clib.c is v1.0.0 (* 6;)" grep -qF '* 6;' "$D/vendor/clib/clib.c"
  check "${L}  marker line 1 = commit" [ "$(sed -n 1p "$D/.mbuild-commit")" = "$W10" ]
  check "${L}  marker line 2 = subs 2" [ "$(sed -n 2p "$D/.mbuild-commit")" = "subs 2" ]
  check "${L}  marker sub lines" [ "$(sed -n 3,4p "$D/.mbuild-commit")" = "sub vendor/clib $C10
sub vendor/clib/third_party/deep $D10" ]
  check "${L}  clib mirror in git/sub" [ -f "$(ls -d "$H"/git/sub/clib@*.git | head -1)/HEAD" ]
  check "${L}  deep mirror in git/sub" [ -f "$(ls -d "$H"/git/sub/deep@*.git | head -1)/HEAD" ]
  check "${L}  no lock left behind" [ -z "$(ls -d "$H"/git/sub/*.lock 2>/dev/null)" ]
  check "${L}  git status clean" [ -z "$(git -C "$D" status --porcelain 2>&1)" ]
  run marker "$P$D"
  check "${L}  git_checkout_commit = first line, complete" out_is "commit $W10
complete 1"
  echo probe >"$D/vendor/clib/.git/mbuild-probe"
  run tree github.com/demo/wrapper v1.1.0 "$P$D"
  check "${L}tree wrapper v1.1.0 over it exits 0" code_is 0
  check "${L}  clib.c is v1.1.0 (* 6 + 1)" grep -qF '* 6 + 1' "$D/vendor/clib/clib.c"
  check "${L}  marker updated" [ "$(sed -n 1p "$D/.mbuild-commit")" = "$W11" ]
  check "${L}  marker subs 2" [ "$(sed -n 2p "$D/.mbuild-commit")" = "subs 2" ]
  check "${L}  nested clone reused" [ -f "$D/vendor/clib/.git/mbuild-probe" ]
  check "${L}  git status clean" [ -z "$(git -C "$D" status --porcelain 2>&1)" ]

  # A one-line marker (before submodules): the parent is kept, subs redone.
  echo "$W11" >"$D/.mbuild-commit"
  rm -rf "$D/vendor/clib"
  mkdir -p "$D/vendor/clib"
  echo kept >"$D/parent-probe"
  run tree github.com/demo/wrapper v1.1.0 "$P$D" --verbose
  check "${L}old marker: exits 0" code_is 0
  check "${L}  parent not re-checked-out" [ -f "$D/parent-probe" ]
  check "${L}  no parent clone" [ -z "$(grep -F 'clone -q --shared' "$S/last.out" | grep -F /github.com/demo/wrapper@)" ]
  check "${L}  submodules back" [ -f "$D/vendor/clib/third_party/deep/include/deep.h" ]
  check "${L}  marker regains subs 2" [ "$(sed -n 2p "$D/.mbuild-commit")" = "subs 2" ]
  rm -f "$D/parent-probe"

  run tree github.com/demo/wrapper v1.1.0 "$P$D" --none
  check "${L}submodules none: exits 0" code_is 0
  check "${L}  marker subs 0 off" [ "$(sed -n 2p "$D/.mbuild-commit")" = "subs 0 off" ]
  check "${L}  vendor/clib empty" [ -d "$D/vendor/clib" ] && [ -z "$(ls -A "$D/vendor/clib")" ]
  run tree github.com/demo/wrapper v1.1.0 "$P$D" --select vendor/nope
  check "${L}select a non-submodule: warning names the real ones" has "$S/last.out" "submodules lists vendor/nope, which is not a submodule at this commit (it has vendor/clib)"
  check "${L}  marker subs 0" [ "$(sed -n 2p "$D/.mbuild-commit")" = "subs 0" ]
  run tree github.com/demo/wrapper v1.1.0 "$P$D" --select vendor/clib
  check "${L}select vendor/clib: checked out with its nested" [ -f "$D/vendor/clib/third_party/deep/include/deep.h" ]

  run tree github.com/demo/absurl v1.0.0 "$P$X/absurl"
  check "${L}absurl (absolute submodule URL) exits 0" code_is 0
  check "${L}  clib/clib.c" [ -f "$X/absurl/clib/clib.c" ]
  check "${L}  deep.h" [ -f "$X/absurl/clib/third_party/deep/include/deep.h" ]
  check "${L}  marker subs 2" [ "$(sed -n 2p "$X/absurl/.mbuild-commit")" = "subs 2" ]

  echo "== ${L}offline, missing commits"
  rm -rf "$H/git/sub"
  run tree github.com/demo/wrapper v1.0.0 "$P$X/off" --offline
  check "${L}offline without sub mirrors: exit 1" code_is 1
  check "${L}  the 12.7 offline error" has "$S/last.out" "submodule vendor/clib of github.com/demo/wrapper v1.0.0 (from $G/clib) is not downloaded and --offline forbids fetching it"
  check "${L}  help line" has "$S/last.out" "help: run \`mbuild fetch\` once while online, or drop --offline"
  check "${L}  incomplete marker" [ -z "$(grep subs "$X/off/.mbuild-commit" 2>/dev/null)" ]

  GB="$F2/gitbase"
  run tree github.com/demo/wrapper v9.0.0 "$P$X/nine"
  check "${L}unpushed gitlink commit: exit 1" code_is 1
  check "${L}  pins commit aaaaaaa, which ... does not have" has "$S/last.out" "submodule vendor/clib of github.com/demo/wrapper v9.0.0 pins commit aaaaaaa, which $F2/gitbase/github.com/demo/clib does not have"
  check "${L}  help names submodules = false" has "$S/last.out" '"github.com/demo/wrapper" = { version = "...", submodules = false }'
  GB="$F/gitbase"

  run clone-url "$DG"
  check "${L}git_clone_url + git_fetch_url" code_is 0
  dangle "${L}dangle"
  run clone-url "$DG"
  check "${L}  clone of an existing mirror: fetch only" code_is 0
  DM=$(ls -d "$H"/git/sub/dangle@*.git | head -1)
  run rev "$P$DM" "$DANGLE"
  check "${L}  dangling commit not in the mirror" out_is "rev "
  run fetch-commit "$P$DM" "$DANGLE"
  check "${L}git_fetch_commit fetches it" out_is "fetch-commit code=0
rev $DANGLE"

  echo "== ${L}links"
  run checkout "$P$WM" "$W10" "$P$T/link"
  check "${L}checkout into a link: refused" has "$S/last.out" "refusing to check out into a linked directory"
  check "${L}  exit 1" code_is 1
  check "${L}  target untouched" [ "$(ls -A "$T/target")" = keep.txt ]
  check "${L}  link still there" [ -L "$T/link" ]
  run tree github.com/demo/wrapper v1.0.0 "$P$T/link"
  check "${L}checkout_tree into a link: refused" has "$S/last.out" "refusing to check out into a linked directory"
  check "${L}  target untouched" [ "$(ls -A "$T/target")" = keep.txt ]
}

GB=""
suite ""

if [ "${1:-}" = "--wine" ]; then
  echo "== building the Windows driver"
  wine "$W017" --build "$(winepath -w "$here/tests/git_driver.mettle" 2>/dev/null)" -o "$(winepath -w "$S/drv.exe" 2>/dev/null)" >"$S/wbuild.log" 2>&1 || { cat "$S/wbuild.log"; exit 1; }
  suite "wine: "
fi

echo
echo "$pass passed, $failed failed"
[ "$failed" = 0 ]
