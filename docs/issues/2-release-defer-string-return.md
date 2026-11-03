-O / --release ICE: "cannot compile function ... (indirect_agg_byname)" when a function returning a string uses defer

any function that returns a `string` (or another aggregate) and has a `defer` in it kills the build at `-O` / `--release` with an internal compiler error. fine at `-O0`, and v0.17.0 builds it fine at `-O` too.

**platform:** linux x86-64, head `v0.17.0-426-g702d838c` built with `make`
**reproduces at:** `-O` and `--release`. not at `-O0`

### repro (`rd2.mettle`)

```mettle
import "std/io";
import "std/mem";

struct L {
  n: int64;
}

fn name_of(l: L*) -> string {
  return "x{l->n}";
}

fn h1(cur: string) -> string {
  var l: L* = new L;
  defer free(l);
  if (l->n == 1) {
    return cur;
  }
  return name_of(l);
}

fn main() -> int32 {
  print(h1("a"));
  return 0;
}
```

### what happens

```
$ mettle --build rd2.mettle -o rd2 && ./rd2
Built executable 'rd2'
x0

$ mettle --build -O rd2.mettle -o rd2
Code generation error: Direct object backend cannot compile function 'h1' (indirect_agg_byname)
Mettle internal compiler error: Code generation failed (Direct object backend cannot compile function 'h1' (indirect_agg_byname))

$ METTLE_MIR_TRACE=1 mettle --build -O rd2.mettle -o rd2
MIR-CALLBAIL	byname	return$$1
Direct object backend cannot compile function 'h1' (indirect_agg_byname)
```

expected it to build and print `x0`.

it still breaks with a single return (`var name: string = name_of(l); return name;`). swapping `defer free(l);` for an explicit `free(l);` before each return builds fine, which is what i'm doing for now.
