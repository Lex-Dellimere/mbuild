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
     Running build/linux/debug/shell/live_demo; its output is held (:log to see it, :unmute to stream it). help for help, :q to leave
  (6 new lines held, :log)
mettle> world
World { tick: 6, pop: 16, food: 55 }
  (3 new lines held, :log)
mettle> world.food = 1000;
ok
  (2 new lines held, :log)
mettle> explain harvest
fn harvest(pop: int32) -> int32  src/rules.mettle:10
  food gathered this tick
  (3 new lines held, :log)
mettle> :log 3
tick 11  pop 22  food 966  (steady)
tick 12  pop 23  food 954  (steady)
tick 13  pop 24  food 941  (steady)
  (2 new lines held, :log)
mettle> :q
```

the program's prints don't flood the prompt: they are held, and a dim line says how many are waiting. `:log [N]` shows the last N, `:unmute` streams them above the prompt (`mbuild shell --stream` starts that way), `:mute` holds them again. when the program exits, its last 5 lines and its exit code print and the shell ends.

- an expression prints its value, a struct field by field. a statement runs and prints `ok`.
- `fn NAME(...) { ... }` replaces `NAME` in the running program; `undo` puts the old one back, `r` patches in the files on disk. `src/` is never touched.
- `ls [FILE]` lists functions, globals and structs by file with the first line of their comment, `apropos TEXT` searches names and comments, `explain NAME` (or `h`) shows a function's signature and comment, a global's value or a struct's fields. `i EXPR` gives a type.
- tab completes names and commands, up and down walk the history, Ctrl-C clears the line.
- `help` lists it all. `:q` or Ctrl-D quits and stops the program. without `mbuild shell`, `shell_point()` is an empty function.

## how it works

- `mbuild live` builds with `--live` and runs the program under `mettle live`, which watches every source file and turns each save into a patch.
- a patch only lands at a `quiesce;`. this program has one at the top of its loop, so a patch lands on the next tick and never halfway through one.
- patching code doesn't touch the world. patches can also change function signatures and struct layouts; values are converted in place.
- linux and windows x64. host target only.
