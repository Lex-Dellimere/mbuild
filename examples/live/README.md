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

`mbuild shell` starts the same program with a shell inside it. what you type runs at its next `shell_point();` (in `main`, next to the `quiesce;`): read the world, change it, redefine a rule, take it back, freeze it between ticks (the tick counts `shell_point()` calls). the world is a global so the shell can reach it.

```bash
cd examples/live
mbuild shell
```

on a terminal it is full screen (`mbuild-shell`, beside `mbuild`); this is a real capture at 80x24 after `ctrl+p`, `world.pop`, `ctrl+n` and setting `food` in `/inspect world`:

```text
 live_demo  ⏸ paused at tick 27 · 0 patches
   Compiling live_demo (linux, debug)
   Running build/linux/debug/shell/live_demo
 ❯ pause
   paused at tick 26
 ❯ world.pop
   19
 ❯ step
   paused at tick 27
 ❯ world.food = 4242;
   ok

   33 lines held · ctrl+o streams · /log shows
────────────────────────────────────────────────────────────────────────────────
 ❯
────────────────────────────────────────────────────────────────────────────────
 ⏸ paused at tick 27 · 0 patches      ctrl+p resume · ctrl+n step · ctrl+d exit
```

- the input stays at the bottom between two rules; answers scroll above it (PgUp/PgDn). the program's prints are held (a dim count says how many): `ctrl+o` streams them into the scrollback, `/log` shows them all.
- `ctrl+p` pauses: `shell_point()` waits, so the program stops between ticks with its state consistent. inputs, watches and patches still work while it waits. `ctrl+n` steps one tick and pauses again. `pause when world.food < 50` pauses at the tick where the condition turns true. only the thread calling `shell_point()` stops; others keep running.
- `/` opens the command palette (`/inspect EXPR`, `/code`, `/watch`, `/log`, `/pause-when`, ...), tab completes names. Esc leaves a view.
- `/inspect world` is a tree: arrows move, Enter expands a struct or pointer, `e` sets the selected field (`world.food = ...;`).
- `/watch` lists the globals and any `watch EXPR`, refreshed every tick.
- `/code` lists the functions and structs, patched ones marked; the right side shows the current source and what a patch replaced. `e` (or `edit harvest`) opens it in `$EDITOR` (vi) and patches it in when you save, `u` undoes that function's patch, `h` its history.
- `fn NAME(...) { ... }` replaces `NAME` in the running program; `undo` takes back the last change, `r` patches in the files on disk. `src/` is never touched.
- `ls`, `apropos TEXT`, `explain NAME`, `i EXPR`, `help` work as in line mode. `ctrl+d` quits and stops the program.

piped, or with `--plain`, it is a line shell with the same commands (`pause`, `resume`, `step`, `status`, `watch`, `unwatch`, `edit`, ...):

```text
$ mbuild shell --plain
   Compiling live_demo (linux, debug)
     Running build/linux/debug/shell/live_demo; its output is held (:log to see it, :unmute to stream it). help for help, :q to leave
  (1 new line held, :log)
mettle> pause
paused at tick 2
mettle> world
World { tick: 1, pop: 11, food: 94 }
  (1 new line held, :log)
mettle> step
paused at tick 3
  (2 new lines held, :log)
mettle> watch world.pop * 2
watching world.pop * 2
mettle> watch
world = World { tick: 2, pop: 12, food: 87 }
world.pop * 2 = 24
mettle> :q
```

without `mbuild shell`, `shell_point()` is an empty function.

## how it works

- `mbuild live` builds with `--live` and runs the program under `mettle live`, which watches every source file and turns each save into a patch.
- a patch only lands at a `quiesce;`. this program has one at the top of its loop, so a patch lands on the next tick and never halfway through one.
- patching code doesn't touch the world. patches can also change function signatures and struct layouts; values are converted in place.
- linux and windows x64. host target only.
