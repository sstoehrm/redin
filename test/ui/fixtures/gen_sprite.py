#!/usr/bin/env python3
"""Deterministic 4x4 RGBA test sprite: top half red, bottom half blue."""
import struct, zlib

W, H = 4, 4
rows = b""
for y in range(H):
    rows += b"\x00"  # filter: none
    for x in range(W):
        rows += bytes([255, 0, 0, 255] if y < H // 2 else [0, 0, 255, 255])

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(rows, 9))
       + chunk(b"IEND", b""))

with open("test/ui/fixtures/sprite.png", "wb") as f:
    f.write(png)
print("wrote test/ui/fixtures/sprite.png")
