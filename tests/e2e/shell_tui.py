"""shell_tui.py: `mbuild shell` full screen (mbuild-shell) driven through a pty.

    python3 -I tests/e2e/shell_tui.py MBUILD PROJECT_DIR OUT_DIR

Prints PASS/FAIL lines; screen captures go to OUT_DIR/tui-80x24.txt and
OUT_DIR/tui-120x40.txt. A small VT emulator reads what mbuild-shell writes
(cursor moves, SGR, erase, the alternate screen; UTF-8, wide characters).
"""

import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time
import unicodedata

MB, PROJ, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name)
    if not ok and detail:
        for line in detail.splitlines()[:60]:
            print("     | " + line)
    sys.stdout.flush()


def width(ch):
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


class Screen:
    def __init__(self, w, h):
        self.resize(w, h)

    def resize(self, w, h):
        self.w, self.h = w, h
        self.rows = [[" "] * w for _ in range(h)]
        self.x = self.y = 0

    def text(self):
        return "\n".join("".join(c for c in r if c is not None).rstrip() for r in self.rows)

    def put(self, ch):
        cw = width(ch)
        if cw == 0:
            return
        if self.x + cw > self.w:
            self.x = 0
            self.y = min(self.y + 1, self.h - 1)
        self.rows[self.y][self.x] = ch
        if cw == 2 and self.x + 1 < self.w:
            self.rows[self.y][self.x + 1] = None
        self.x += cw

    def feed(self, data):
        s = data.decode("utf-8", "replace")
        i = 0
        while i < len(s):
            c = s[i]
            if c == "\x1b":
                if i + 1 < len(s) and s[i + 1] == "[":
                    j = i + 2
                    while j < len(s) and not ("\x40" <= s[j] <= "\x7e"):
                        j += 1
                    if j >= len(s):
                        return s[i:].encode()
                    params, fin = s[i + 2:j], s[j]
                    self.csi(params, fin)
                    i = j + 1
                    continue
                i += 2
                continue
            if c == "\r":
                self.x = 0
            elif c == "\n":
                self.y = min(self.y + 1, self.h - 1)
            elif c >= " ":
                self.put(c)
            i += 1
        return b""

    def csi(self, params, fin):
        if params.startswith("?"):
            return
        nums = [int(p) if p.isdigit() else 0 for p in params.split(";")] if params else []
        if fin == "H":
            self.y = max(0, min((nums[0] if nums else 1) - 1, self.h - 1))
            self.x = max(0, min((nums[1] if len(nums) > 1 else 1) - 1, self.w - 1))
        elif fin == "J" and nums[:1] == [2]:
            self.rows = [[" "] * self.w for _ in range(self.h)]
        elif fin == "K":
            for k in range(self.x, self.w):
                self.rows[self.y][k] = " "


def set_size(fd, w, h):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", h, w, 0, 0))


pid, fd = pty.fork()
if pid == 0:
    os.chdir(PROJ)
    os.environ["TERM"] = "xterm-256color"
    os.execv(MB, [MB, "shell"])

set_size(fd, 80, 24)
scr = Screen(80, 24)
rest = b""


def pump(seconds):
    global rest
    end = time.time() + seconds
    while True:
        left = end - time.time()
        if left <= 0:
            return
        r, _, _ = select.select([fd], [], [], min(left, 0.05))
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            if not data:
                return
            rest = scr.feed(rest + data)


def wait_for(pred, seconds):
    end = time.time() + seconds
    while time.time() < end:
        pump(0.1)
        if pred(scr.text()):
            return True
    return False


def send(b):
    os.write(fd, b)


def lines():
    return scr.text().splitlines()


def capture(name):
    with open(os.path.join(OUT, name), "w") as f:
        f.write(scr.text() + "\n")


def answer_after(cmd):
    ls = lines()
    for i, l in enumerate(ls):
        if l.strip() == "❯ " + cmd and i + 1 < len(ls):
            return ls[i + 1].strip()
    return None


up = wait_for(lambda t: "● running" in t and "tick" in t, 90)
check("tui starts: header and footer show the program running", up, scr.text())
t = scr.text()
check("header names the program", lines()[0].strip().startswith("live_demo"), t)
check("footer has the key hints", "ctrl+p pause" in lines()[-1] and "ctrl+d exit" in lines()[-1], t)
check("input between two rules", sum(1 for l in lines() if l.strip().startswith("────")) >= 2 and any(l.strip() == "❯" for l in lines()), t)
check("output held by default", wait_for(lambda t: "lines held" in t, 10), scr.text())

send(b"/")
ok = wait_for(lambda t: "/inspect" in t and "/code" in t and "/pause-when" in t, 5)
check("/ opens the command palette", ok, scr.text())
send(b"\x1b")
pump(0.3)
send(b"\x15")

send(b"/watch\r")
ok = wait_for(lambda t: any(l.strip().lstrip("› ").startswith("world") and "World { tick:" in l for l in t.splitlines()), 10)
check("watch view: world and its value", ok, scr.text())
send(b"\x1b")
pump(0.3)

send(b"\x10")
ok = wait_for(lambda t: "⏸ paused at tick" in t, 10)
check("ctrl+p pauses", ok, scr.text())
paused_tick = None
for l in lines():
    if "paused at tick" in l:
        paused_tick = l.split("paused at tick")[1].split()[0]
pump(0.5)
check("paused: the tick stays", paused_tick is not None and ("paused at tick " + paused_tick) in lines()[-1], scr.text())

send(b"world.pop\r")
ok = wait_for(lambda t: (answer_after("world.pop") or "").isdigit(), 10)
check("world.pop answers in the scrollback", ok, scr.text())

send(b"\x0e")
ok = wait_for(lambda t: paused_tick is not None and ("paused at tick " + str(int(paused_tick) + 1)) in t.splitlines()[-1], 10)
check("ctrl+n steps one tick", ok, scr.text())

send(b"/inspect world\r")
ok = wait_for(lambda t: "Inspect  world" in t and any(l.strip().startswith("food") and "int32" in l for l in t.splitlines()), 10)
check("/inspect world: a tree with the fields", ok, scr.text())
send(b"\x1b[B\x1b[B\x1b[B")
pump(0.2)
send(b"e")
pump(0.2)
send(b"\x15" + b"4242\r")
ok = wait_for(lambda t: any(l.strip().lstrip("› ").startswith("food") and "4242" in l for l in t.splitlines()), 10)
check("inspect: e sets a field", ok, scr.text())
capture("tui-inspect.txt")
send(b"\x1b")
pump(0.3)
capture("tui-80x24.txt")

set_size(fd, 120, 40)
os.kill(pid, signal.SIGWINCH)
scr.resize(120, 40)
ok = wait_for(lambda t: len(t.splitlines()) >= 39 and "ctrl+d exit" in t.splitlines()[-1], 10)
check("resize to 120x40 redraws", ok, scr.text())
send(b"/code harvest\r")
ok = wait_for(lambda t: "return pop / 2;" in t, 10)
check("/code: the source of the selected function", ok, scr.text())
send(b"\x1b")
pump(0.3)
send(b"fn harvest(pop: int32) -> int32 { return pop * 3; }\r")
ok = wait_for(lambda t: answer_after("fn harvest(pop: int32) -> int32 { return pop * 3; }") == "redefined harvest", 15)
check("fn redefines in the tui", ok, scr.text())
send(b"pause when world.food < 0\r")
wait_for(lambda t: "pause when world.food < 0" in t.splitlines()[-1], 10)
send(b"\x10")
ok = wait_for(lambda t: "● running" in t.splitlines()[-1], 10)
check("ctrl+p resumes", ok, scr.text())
pump(0.5)
capture("tui-120x40.txt")

set_size(fd, 30, 8)
os.kill(pid, signal.SIGWINCH)
scr.resize(30, 8)
ok = wait_for(lambda t: "❯" in t, 5)
check("a narrow terminal: clipped, never wrapped", ok and all(len(l) <= 30 for l in lines()), scr.text())
capture("tui-30x8.txt")

send(b"\x04")
code = None
end = time.time() + 15
while time.time() < end:
    pump(0.1)
    got, status = os.waitpid(pid, os.WNOHANG)
    if got == pid:
        code = os.waitstatus_to_exitcode(status)
        break
check("ctrl+d leaves with 0", code == 0, "exit: %r" % (code,))
print("shell_tui: %d passed, %d failed" % (sum(results), len(results) - sum(results)))
