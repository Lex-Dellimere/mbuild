--release ICE: "cannot compile function ... (global_access)" after nested inlining of string helpers

hit this while writing mbuild (build tool for mettle, written in mettle). a function calling small string helpers that call other small string helpers builds fine at `-O0` but `--release` dies with an internal compiler error. v0.17.0 builds the same file fine at `--release`, so it's new since then.

**platform:** linux x86-64, head `v0.17.0-426-g702d838c` built with `make`
**reproduces at:** `--release`. not at `-O0`

### repro (`r10.mettle`)

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

### what happens

```
$ mettle --build r10.mettle -o r10 && ./r10
Built executable 'r10'
0

$ mettle --build --release r10.mettle -o r10
Code generation error: Direct object backend cannot compile function 'tml_scalar' (global_access)
Mettle internal compiler error: Code generation failed (Direct object backend cannot compile function 'tml_scalar' (global_access))

$ METTLE_MIR_TRACE=1 mettle --build --release r10.mettle -o r10
MIR-CALLBAIL	global_write	__inl_9_local___inl_4_param_s
Code generation error: Direct object backend cannot compile function 'tml_scalar' (global_access)
```

expected it to build and print `0` like it does at `-O0` and on v0.17.0.

### what i think is going on

after nested inlining the inlined string param gets split into field locals and its own declaration is dropped, but a whole-aggregate copy into it is still there:

```
local @__inl_281_local___inl_20_param_s$8 : uint64
@__inl_281_local___inl_20_param_s <- @__inl_281_param_a
```

then `mir_scan_global_write` in `src/codegen/binary/mir_lower.c` sees the undeclared name, treats it as a global write and bails on the whole function.

### workaround

reading `(int64)s.length` directly instead of calling the one-line `slen` helper inside the other helpers. that stops the nesting and it builds.
