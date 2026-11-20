# make.py: the PNG fixtures of tests/unit/png_test.mettle (python3 make.py, in this directory).
# pixels follow the formulas png_test.mettle checks; rows use filters 0-4 in turn.
import struct, zlib

W, H = 16, 8

def rgba(x, y):
    return ((x * 16 + y * 3) & 255, (y * 32 + x * 5) & 255, (x * y * 7 + 40) & 255, (255 - x * 4 - y * 9) & 255)

def gray(x, y):
    return (x * 15 + y * 11) & 255

def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)

def filtered(rows, bpp):
    out, prev = b"", bytes(len(rows[0]))
    for y, row in enumerate(rows):
        f = y % 5
        line = bytearray([f])
        for i, v in enumerate(row):
            a = row[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            pred = [0, a, b, (a + b) // 2, paeth(a, b, c)][f]
            line.append((v - pred) & 255)
        out += bytes(line)
        prev = row
    return out

def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)

def png(name, w, h, ctype, rows, bpp, level=6, strategy=zlib.Z_DEFAULT_STRATEGY, extra=b"", depth=8, interlace=0, want_btype=None):
    c = zlib.compressobj(level, zlib.DEFLATED, 15, 9, strategy)
    z = c.compress(filtered(rows, bpp)) + c.flush()
    if want_btype is not None:
        assert (z[2] >> 1) & 3 == want_btype, (name, (z[2] >> 1) & 3)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, depth, ctype, 0, 0, interlace)) + extra + chunk(b"IDAT", z) + chunk(b"IEND", b"")
    open(name, "wb").write(data)

def rows_rgba(w, h, tweak=None):
    rows = []
    for y in range(h):
        r = bytearray()
        for x in range(w):
            p = list(rgba(x, y))
            if tweak:
                tweak(x, y, p)
            r += bytes(p)
        rows.append(bytes(r))
    return rows

png("g8.png", W, H, 0, [bytes(gray(x, y) for x in range(W)) for y in range(H)], 1)
png("g8_key.png", W, H, 0, [bytes(gray(x, y) for x in range(W)) for y in range(H)], 1, extra=chunk(b"tRNS", struct.pack(">H", gray(1, 0))))
png("ga8.png", W, H, 4, [bytes(v for x in range(W) for v in (gray(x, y), rgba(x, y)[3])) for y in range(H)], 2)
png("rgb8.png", W, H, 2, [bytes(v for x in range(W) for v in rgba(x, y)[:3]) for y in range(H)], 3)
pal = b"".join(bytes((i * 5, 255 - i * 5, i * 3)) for i in range(50))
png("pal8.png", W, H, 3, [bytes((x * 3 + y) % 50 for x in range(W)) for y in range(H)], 1, extra=chunk(b"PLTE", pal) + chunk(b"tRNS", bytes(255 - i for i in range(50))))
png("rgba8_stored.png", W, H, 6, rows_rgba(W, H), 4, level=0, want_btype=0)
png("rgba8_fixed.png", W, H, 6, rows_rgba(W, H), 4, strategy=zlib.Z_FIXED, want_btype=1)
png("rgba8.png", W, H, 6, rows_rgba(W, H), 4)
png("rgba8_dyn.png", 64, 32, 6, rows_rgba(64, 32), 4, level=9, want_btype=2)
def near(x, y, p):
    if y == 0 and x == 0: p[0] = (p[0] + 2) & 255
    if y == 0 and x == 1: p[1] = (p[1] + 3) & 255
    if y == 0 and x == 2: p[2] = (p[2] + 48) & 255
png("rgba8_near.png", W, H, 6, rows_rgba(W, H, near), 4)
png("rgba8_wide.png", W + 1, H, 6, rows_rgba(W + 1, H), 4)
png("interlaced.png", W, H, 6, rows_rgba(W, H), 4, interlace=1)
png("g16.png", W, H, 0, [bytes(v for x in range(W) for v in (gray(x, y), 0)) for y in range(H)], 2, depth=16)
