# live patching

a tiny world that ticks twice a second. its rules live in `src/rules.mettle`, and you change them while it runs: the next tick uses the new code and the world carries on where it was.

```bash
cd examples/live
mbuild live
```

then, in another terminal or your editor, change `src/rules.mettle` and save. here `rule_name` became `"boom"` and `harvest` went from `pop / 2` to `pop * 3`:

```text
tick 7  pop 18  food 36  (steady)
tick 8  pop 19  food 26  (steady)
Patch 1: rule_name, harvest (600 bytes)
[live] patch 1: 2 functions
tick 9  pop 20  food 63  (boom)
tick 10  pop 21  food 102  (boom)
tick 11  pop 22  food 143  (boom)
```

## crashes don't end it

break a rule on purpose, e.g. make `harvest` divide by zero, and save. the program stops at the fault instead of dying. save a fix and it picks up from its last tick, state and all:

```text
tick 6  pop 17  food 46  (steady)
Patch 1: harvest (464 bytes)
[live] patch 1: 1 function
Unhandled runtime signal 8 (arithmetic exception (e.g. integer divide by zero))
...
  #0 harvest at .../src/rules.mettle:10:14 (0x000000000070002A)
  #1 main at src/main.mettle:23:38 (0x000000000041E0AF)
[live] main stopped at the fault. Save a fix and it continues from its last quiesce point
Patch 2: harvest (360 bytes)
[live] patch 2: 1 function
[live] main continues from its last quiesce point
tick 7  pop 18  food 36  (steady)
```

## poke it from the prompt

`mbuild shell` starts the same program with a `mettle> ` prompt inside it. what you type runs at its next `shell_point();` (in `main`, next to the `quiesce;`): read the world, change it, redefine a rule, take it back. the world is a global so the prompt can reach it.

```bash
cd examples/live
mbuild shell
```

```text
$ mbuild shell
   Compiling live_demo (linux, debug)
     Running build/linux/debug/shell/live_demo; help for help, :q to leave
tick 0  pop 11  food 94  (steady)
tick 1  pop 12  food 87  (steady)
tick 2  pop 13  food 80  (steady)
tick 3  pop 14  food 72  (steady)
tick 4  pop 15  food 64  (steady)
mettle> world.pop
tick 5  pop 16  food 55  (steady)
15
tick 6  pop 17  food 46  (steady)
tick 7  pop 18  food 36  (steady)
tick 8  pop 19  food 26  (steady)
mettle> world
tick 9  pop 19  food 16  (steady)
World { tick: 9, pop: 19, food: 26 }
tick 10  pop 19  food 6  (steady)
tick 11  pop 19  food 0  (steady)
mettle> world.food = 1000;
tick 12  pop 19  food 0  (steady)
tick 13  pop 20  food 989  (steady)
ok
tick 14  pop 21  food 978  (steady)
tick 15  pop 22  food 966  (steady)
mettle> fn harvest(pop: int32) -> int32 { return pop * 3; }
redefined harvest
tick 16  pop 23  food 954  (steady)
tick 17  pop 24  food 941  (steady)
tick 18  pop 25  food 928  (steady)
tick 19  pop 26  food 914  (steady)
tick 20  pop 27  food 965  (steady)
tick 21  pop 28  food 1018  (steady)
tick 22  pop 29  food 1073  (steady)
mettle> harvest(world.pop)
tick 23  pop 30  food 1130  (steady)
tick 24  pop 31  food 1189  (steady)
90
tick 25  pop 32  food 1250  (steady)
tick 26  pop 33  food 1313  (steady)
tick 27  pop 34  food 1378  (steady)
mettle> undo
undone
tick 28  pop 35  food 1360  (steady)
tick 29  pop 36  food 1341  (steady)
mettle> harvest(world.pop)
tick 30  pop 37  food 1322  (steady)
tick 31  pop 38  food 1302  (steady)
18
tick 32  pop 39  food 1282  (steady)
tick 33  pop 40  food 1261  (steady)
mettle> h grow
fn grow(pop: int32, food: int32) -> int32  src/rules.mettle:14
  population next tick
tick 34  pop 41  food 1240  (steady)
tick 35  pop 42  food 1218  (steady)
mettle> :q
```

- an expression prints its value, a struct field by field. a statement runs and prints `ok`.
- `fn NAME(...) { ... }` replaces `NAME` in the running program; `undo` puts the old one back, `r` patches in the files on disk. `src/` is never touched.
- `h NAME` shows a signature and its comment, `i EXPR` a type and its fields. tab completes names, up and down walk the history.
- `:q` or Ctrl-D quits and stops the program. without `mbuild shell`, `shell_point()` is an empty function.

## how it works

- `mbuild live` builds with `--live` and runs the program under `mettle live`, which watches every source file and turns each save into a patch.
- a patch only lands at a `quiesce;`. this program has one at the top of its loop, so a patch lands on the next tick and never halfway through one.
- patching code doesn't touch the world. patches can also change function signatures and struct layouts; values are converted in place.
- linux and windows x64. host target only.
