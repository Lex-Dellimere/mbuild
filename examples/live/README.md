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
Patch 1: harvest (504 bytes)
[live] patch 1: 1 function
Unhandled runtime signal 8 (arithmetic exception (e.g. integer divide by zero))
...
  #0 harvest at .../src/rules.mettle:11:14 (0x0000000000700030)
  #1 main at src/main.mettle:19:30 (0x000000000041E05C)
[live] main stopped at the fault. Save a fix and it continues from its last quiesce point
Patch 2: harvest (360 bytes)
[live] patch 2: 1 function
[live] main continues from its last quiesce point
tick 7  pop 18  food 36  (steady)
```

## how it works

- `mbuild live` builds with `--live` and runs the program under `mettle live`, which watches every source file and turns each save into a patch.
- a patch only lands at a `quiesce;`. this program has one at the top of its loop, so a patch lands on the next tick and never halfway through one.
- the world is a local in `main`, so patching code doesn't touch it. patches can also change function signatures and struct layouts; values are converted in place.
- linux and windows x64. host target only.
