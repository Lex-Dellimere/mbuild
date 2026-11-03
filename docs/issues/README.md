issues for mettle, ready to paste. first line of each file is the title, everything under it is the body.

1. `1-release-global-access.md`: `--release` ICE (global_access) after nested inlining
2. `2-release-defer-string-return.md`: `-O` ICE (indirect_agg_byname) with defer in a string-returning fn
3. `3-std-mem-import-hides-declarations.md`: importing std/mem hides a no-export module's declarations

all reproduced 2026-11-02 on head `v0.17.0-426-g702d838c` (linux, built with make) and the v0.17.0 releases.

not filed because head already fixed it: on the v0.17.0 linux release, calling an `export fn` whose string arg would start in the 6th int register crashes codegen with `Out of memory loading SysV aggregate arg registers`, e.g. `five(p: int64, a: string, b: string, c: string)` called from another module. head and the v0.17.0 windows release build it fine. might be worth a regression test.
