# Mettle compiler bugs found while building mbuild

Four compiler bugs turned up while writing mbuild. Each has a minimal
reproducer below, ready to file upstream. mbuild works around all four (the
rules are in `DESIGN.md` section 2), and `tools/mcheck.sh` builds every test
entry with each affected compiler so a regression shows up at once.

Compilers: **head** is `Mettle` at `702d838c` (v0.17.0-426), built on Linux;
**v0.17.0** is the release from GitHub, Linux and Windows.

## A. head, `-O`/`--release`: "cannot compile function ... (global_access)"

After nested inlining, an inlined string parameter is split into field locals
and its own declaration is dropped, but the whole-aggregate copy into it
remains:

```text
local @__inl_281_local___inl_20_param_s$8 : uint64
@__inl_281_local___inl_20_param_s <- @__inl_281_param_a
```

`mir_scan_global_write` (`src/codegen/binary/mir_lower.c`) then reads the
undeclared name as a global write and bails.

Reproducer (`r10.mettle`):

```mettle
import "std/io";
fn slen(s: string) -> int64 {
  return (int64)s.length;
}
fn s_view(p: uint8*, n: int64) -> string {
  var s: string;
  s.chars = p;
  s.length = (uint64)n;
  return s;
}
fn s_sub(s: string, start: int64, end: int64) -> string {
  var n: int64 = slen(s);
  if (start < 0) { start = 0; }
  if (end > n) { end = n; }
  if (end <= start) {
    return s_view((uint8*)"".chars, 0);
  }
  return s_view(&s.chars[start], end - start);
}
fn s_byte(s: string, i: int64) -> int32 {
  return (int32)s.chars[i];
}
fn s_eq(a: string, b: string) -> bool {
  var n: int64 = slen(a);
  if (n != slen(b)) {
    return false;
  }
  var i: int64 = 0;
  while (i < n) {
    if (a.chars[i] != b.chars[i]) {
      return false;
    }
    i = i + 1;
  }
  return true;
}
fn is_digit_b(c: int32) -> bool {
  return c >= 48 && c <= 57;
}
struct TmlP {
  text: string;
  pos: int64;
}
fn tml_c(p: TmlP*) -> int32 {
  if (p->pos >= slen(p->text)) {
    return -1;
  }
  return s_byte(p->text, p->pos);
}
fn tml_value_ends(c: int32) -> bool {
  return c == -1 || c == 32;
}
fn tml_scalar(p: TmlP*) -> int32 {
  var start: int64 = p->pos;
  var word: string = s_sub(p->text, start, p->pos);
  if (s_eq(word, "true") || s_eq(word, "false")) {
  }
  var i: int64 = 0;
  var ok: bool = slen(word) > 0 && tml_value_ends(tml_c(p));
  var digits: int64 = 0;
  while (ok && i < slen(word)) {
    var d: int32 = s_byte(word, i);
    var sep_ok: bool = d == 95 && digits > 0 && i + 1 < slen(word) && is_digit_b(s_byte(word, i + 1));
  }
  return 0;
}
fn main(argc: int32, argv: cstring*) -> int32 {
  var p: TmlP* = new TmlP;
  p->text = "true";
  print("{tml_scalar(p)}\n");
  return 0;
}
```

```text
$ METTLE_MIR_TRACE=1 mettle --build r10.mettle -o r10 --release
MIR-CALLBAIL	global_write	__inl_9_local___inl_4_param_s
Code generation error: Direct object backend cannot compile function 'tml_scalar' (global_access)
```

Debug builds work. v0.17.0 `--release` works.

## B. head, `-O`/`--release`: `defer` in a function returning a string

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

```text
$ METTLE_MIR_TRACE=1 mettle --build rd2.mettle -o rd2 -O
MIR-CALLBAIL	byname	return$$1
Direct object backend cannot compile function 'h1' (indirect_agg_byname)
```

It fails with a single `return` too. An explicit `free(l)` before each
`return` works, and v0.17.0 works.

## C. head and v0.17.0: importing `std/mem` hides a module's declarations

A module with no `export` of its own is meant to be entirely public. If it
imports `std/mem` (or `std/conv`), its declarations disappear from every
importer.

`lib.mettle`:

```mettle
import "std/mem";

fn lib_answer() -> int32 {
  return 42;
}
```

`main.mettle`:

```mettle
import "std/io";
import "lib";

fn main() -> int32 {
  print("{lib_answer()}\n");
  return 0;
}
```

```text
$ mettle --build main.mettle -o m
error[E0003]: Undefined function 'lib_answer'
```

The same happens on head, v0.17.0 Linux and v0.17.0 Windows. Without the
`std/mem` import it prints 42, and importing `std/io` instead also works. The
likely cause is the `has_any_export` scan (`src/semantic/import_resolver.c`):
it runs over a declaration list that already contains the `export extern`
declarations spliced in from `std/mem`.

## D. v0.17.0 Linux: a string argument starting in the 6th register slot

`lib.mettle`:

```mettle
export fn five(p: int64, a: string, b: string, c: string) -> int64 {
  return p + (int64)a.length + (int64)b.length + (int64)c.length;
}
```

`main.mettle`:

```mettle
import "lib";

fn main() -> int32 {
  return (int32)five(1, "a", "bb", "ccc");
}
```

```text
$ mettle --build main.mettle -o m        (v0.17.0 Linux)
Code generation error: Out of memory loading SysV aggregate arg registers
```

Head and v0.17.0 Windows build it, and the program exits with 7. The rule:
the crash happens on a call to an exported function when a string argument
would begin in the sixth integer register (a string takes two, and a returned
struct over 16 bytes takes one hidden register first). It is fixed in head
and matters only to code that must build with v0.17.0.

## Also observed

- A local variable with the same name as a function crashes v0.17.0 code
  generation: "Direct object backend cannot store aggregate symbol 'out'".
- An import that names a directory resolves to that directory on Linux:
  `file_exists_readable` is an `fopen(path, "r")`, which succeeds on a
  directory there. The compiler then reports confusing undefined names
  rather than "is a directory".
- Each internal linker reports only the first unresolved symbol of a link.
