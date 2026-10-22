#!/usr/bin/env python3
"""Generate optional Phase 01 fallback atlases using Python stdlib only."""

from __future__ import annotations

import binascii
import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".build/placeholder-atlases"


class Canvas:
    def __init__(self, width: int, height: int):
        self.width = width
        self.height = height
        self.pixels = bytearray(width * height * 4)

    def blend(self, x: int, y: int, color: tuple[int, int, int, int]):
        if not (0 <= x < self.width and 0 <= y < self.height):
            return
        i = (y * self.width + x) * 4
        sr, sg, sb, sa = color
        if sa == 255:
            self.pixels[i : i + 4] = bytes(color)
            return
        da = self.pixels[i + 3]
        out_a = sa + da * (255 - sa) // 255
        if out_a == 0:
            return
        for offset, source in enumerate((sr, sg, sb)):
            dest = self.pixels[i + offset]
            self.pixels[i + offset] = (source * sa + dest * da * (255 - sa) // 255) // out_a
        self.pixels[i + 3] = out_a

    def ellipse(self, cx: float, cy: float, rx: float, ry: float, color):
        left, right = int(cx - rx), int(cx + rx) + 1
        top, bottom = int(cy - ry), int(cy + ry) + 1
        for y in range(top, bottom):
            for x in range(left, right):
                if ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1:
                    self.blend(x, y, color)

    def rect(self, x: int, y: int, width: int, height: int, color):
        for py in range(y, y + height):
            for px in range(x, x + width):
                self.blend(px, py, color)

    def polygon(self, points, color):
        min_y = max(0, int(min(p[1] for p in points)))
        max_y = min(self.height - 1, int(max(p[1] for p in points)))
        for y in range(min_y, max_y + 1):
            intersections = []
            for a, b in zip(points, points[1:] + points[:1]):
                if (a[1] <= y < b[1]) or (b[1] <= y < a[1]):
                    t = (y - a[1]) / (b[1] - a[1])
                    intersections.append(a[0] + t * (b[0] - a[0]))
            intersections.sort()
            for left, right in zip(intersections[::2], intersections[1::2]):
                for x in range(int(left), int(right) + 1):
                    self.blend(x, y, color)

    def line(self, x0, y0, x1, y1, width, color):
        steps = int(math.ceil(max(abs(x1 - x0), abs(y1 - y0), 1)))
        for index in range(steps + 1):
            t = index / steps
            self.ellipse(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, width / 2, width / 2, color)


INK = (30, 55, 92, 255)
HAIR = (48, 101, 152, 255)
HAIR_LIGHT = (94, 177, 213, 255)
SKIN = (255, 224, 204, 255)
HOODIE = (53, 139, 196, 255)
HOODIE_LIGHT = (102, 201, 226, 255)
WHITE = (250, 253, 255, 255)
BLUSH = (248, 137, 157, 190)


def face(canvas: Canvas, ox: int, cx: float, cy: float, scale: float, expression: int):
    cx += ox
    canvas.ellipse(cx, cy - 2 * scale, 31 * scale, 33 * scale, INK)
    canvas.ellipse(cx, cy, 29 * scale, 31 * scale, HAIR)
    canvas.polygon([(cx - 29 * scale, cy - 4 * scale), (cx - 18 * scale, cy - 35 * scale), (cx - 2 * scale, cy - 21 * scale)], HAIR_LIGHT)
    canvas.polygon([(cx + 29 * scale, cy - 4 * scale), (cx + 18 * scale, cy - 35 * scale), (cx + 2 * scale, cy - 21 * scale)], HAIR_LIGHT)
    canvas.ellipse(cx, cy + 5 * scale, 21 * scale, 19 * scale, SKIN)
    canvas.ellipse(cx - 13 * scale, cy + 12 * scale, 5 * scale, 3 * scale, BLUSH)
    canvas.ellipse(cx + 13 * scale, cy + 12 * scale, 5 * scale, 3 * scale, BLUSH)
    if expression == 1:
        canvas.line(cx - 13 * scale, cy + 2 * scale, cx - 5 * scale, cy + 2 * scale, max(1, int(2 * scale)), INK)
        canvas.line(cx + 5 * scale, cy + 2 * scale, cx + 13 * scale, cy + 2 * scale, max(1, int(2 * scale)), INK)
    else:
        canvas.ellipse(cx - 9 * scale, cy + 1 * scale, 2.5 * scale, (4 if expression == 2 else 5) * scale, INK)
        canvas.ellipse(cx + 9 * scale, cy + 1 * scale, 2.5 * scale, (4 if expression == 2 else 5) * scale, INK)
    if expression == 3:
        canvas.line(cx - 5 * scale, cy + 17 * scale, cx + 5 * scale, cy + 14 * scale, max(1, int(2 * scale)), INK)
    else:
        canvas.ellipse(cx, cy + 15 * scale, 4 * scale, (3 if expression == 2 else 2) * scale, INK)
    # Small whale-fin hair ornaments.
    canvas.polygon([(cx - 20 * scale, cy - 23 * scale), (cx - 35 * scale, cy - 31 * scale), (cx - 28 * scale, cy - 14 * scale)], HOODIE_LIGHT)
    canvas.polygon([(cx + 20 * scale, cy - 23 * scale), (cx + 35 * scale, cy - 31 * scale), (cx + 28 * scale, cy - 14 * scale)], HOODIE_LIGHT)


def draw_mini(canvas: Canvas, frame: int, frame_width: int):
    face(canvas, frame * frame_width, frame_width / 2, frame_width / 2, 0.85, frame)


def draw_peek(canvas: Canvas, frame: int, frame_width: int):
    ox = frame * frame_width
    cx = ox + frame_width / 2
    bob = [0, -3, 1, 0][frame]
    canvas.ellipse(cx, 143 + bob, 54, 39, INK)
    canvas.ellipse(cx, 141 + bob, 50, 36, HOODIE)
    canvas.ellipse(cx, 146 + bob, 32, 24, WHITE)
    # Arms hugging the menu edge / waving.
    canvas.line(cx - 38, 130 + bob, cx - 60, 156 + bob, 14, HOODIE)
    if frame == 2:
        canvas.line(cx + 38, 131 + bob, cx + 64, 91 + bob, 14, HOODIE)
        canvas.ellipse(cx + 66, 86 + bob, 8, 8, SKIN)
    else:
        canvas.line(cx + 38, 130 + bob, cx + 59, 156 + bob, 14, HOODIE)
    face(canvas, ox, frame_width / 2, 74 + bob, 1.25, frame)
    canvas.rect(ox + 18, 166, frame_width - 36, 7, INK)


def draw_full(canvas: Canvas, frame: int, frame_width: int):
    ox = frame * frame_width
    cx = ox + frame_width / 2
    bob = [0, -3, 2, 0][frame]
    # Hair behind body.
    canvas.ellipse(cx, 133 + bob, 58, 88, INK)
    canvas.ellipse(cx, 130 + bob, 54, 84, HAIR)
    # Legs and shoes.
    canvas.line(cx - 25, 190 + bob, cx - 29, 238 + bob, 18, (34, 82, 139, 255))
    canvas.line(cx + 25, 190 + bob, cx + 29, 238 + bob, 18, (34, 82, 139, 255))
    canvas.ellipse(cx - 34, 244 + bob, 19, 10, INK)
    canvas.ellipse(cx + 34, 244 + bob, 19, 10, INK)
    # Hoodie and whale belly.
    canvas.ellipse(cx, 157 + bob, 52, 63, INK)
    canvas.ellipse(cx, 155 + bob, 48, 60, HOODIE)
    canvas.ellipse(cx, 169 + bob, 31, 39, WHITE)
    # Arms: dragged frame reaches upward, poke frame crosses arms.
    if frame == 2:
        canvas.line(cx - 39, 139 + bob, cx - 64, 100 + bob, 17, HOODIE)
        canvas.line(cx + 39, 139 + bob, cx + 64, 100 + bob, 17, HOODIE)
    elif frame == 3:
        canvas.line(cx - 39, 140 + bob, cx + 18, 164 + bob, 17, HOODIE)
        canvas.line(cx + 39, 140 + bob, cx - 18, 164 + bob, 17, HOODIE)
    else:
        canvas.line(cx - 39, 140 + bob, cx - 62, 181 + bob, 17, HOODIE)
        canvas.line(cx + 39, 140 + bob, cx + 62, 181 + bob, 17, HOODIE)
    face(canvas, ox, frame_width / 2, 72 + bob, 1.35, frame)


def chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)


def write_png(path: Path, canvas: Canvas):
    rows = bytearray()
    stride = canvas.width * 4
    for y in range(canvas.height):
        rows.append(0)
        rows.extend(canvas.pixels[y * stride : (y + 1) * stride])
    data = b"\x89PNG\r\n\x1a\n"
    data += chunk(b"IHDR", struct.pack(">IIBBBBB", canvas.width, canvas.height, 8, 6, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    data += chunk(b"IEND", b"")
    path.write_bytes(data)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, width, height, drawer in [
        ("mini-atlas", 96, 96, draw_mini),
        ("peek-atlas", 180, 180, draw_peek),
        ("full-atlas", 220, 260, draw_full),
    ]:
        canvas = Canvas(width * 4, height)
        for frame in range(4):
            drawer(canvas, frame, width)
        write_png(OUT / f"{name}.png", canvas)


if __name__ == "__main__":
    main()
