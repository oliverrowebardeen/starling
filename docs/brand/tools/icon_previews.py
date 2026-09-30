#!/usr/bin/env python3
"""Render the Starling app icon in all six iOS appearances and measure it.

Usage (from the repo root, needs Xcode 27 and Pillow):

    python3 docs/brand/tools/icon_previews.py

Writes docs/brand/previews/*.png and prints a Markdown table with:

- gap: how far the knocked-out overlap drifts from the icon background,
  measured inside the overlap, 8 px in from its edge at 1024 px.
  dE is CIELAB Delta E 1976; about 2.3 is a just noticeable difference.
  "darker" is the share of gap pixels whose L* is more than 2.3 below
  the background, which is what a shadow falling into the gap produces.
- A vs B: how distinct the two shapes stay (Delta E and WCAG contrast).

Also renders the default appearance at every shadow opacity in
SHADOW_SWEEP, from copies of the bundle, to show why ADR 0171 picked 0.2.
"""

import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
ICON = os.path.join(ROOT, "App", "Resources", "Starling.icon")
OUT = os.path.join(ROOT, "docs", "brand", "previews")
ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
RENDITIONS = ["Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark"]
FILE_NAMES = {
    "Default": "icon-default.png",
    "Dark": "icon-dark.png",
    "ClearLight": "icon-clear-light.png",
    "ClearDark": "icon-clear-dark.png",
    "TintedLight": "icon-tinted-light.png",
    "TintedDark": "icon-tinted-dark.png",
}
SHADOW_SWEEP = [0.5, 0.4, 0.3, 0.25, 0.2, 0.15, 0.1, 0.0]

# Geometry of the mark in logo units, matching StarlingDesign's MarkGeometry
# logo pose: two 40 x 56 rectangles with corner radius 14, centers at
# (-10, -8) and (10, 8) in a frame rotated 20 degrees clockwise.
# In the 1024 px icon canvas one unit is 123.29 / 14 px (the SVG corner radius).
UNIT_PX = 123.29 / 14


def rounded_rect_contains(x, y, cx, cy, w=40.0, h=56.0, r=14.0):
    if abs(x - cx) > w / 2 or abs(y - cy) > h / 2:
        return False
    dx = max(abs(x - cx) - (w / 2 - r), 0.0)
    dy = max(abs(y - cy) - (h / 2 - r), 0.0)
    return dx * dx + dy * dy <= r * r


def pixel_to_unit(px, py, size):
    scale = size / 1024
    x = (px + 0.5 - size / 2) / scale
    y = (py + 0.5 - size / 2) / scale
    c, s = math.cos(math.radians(20)), math.sin(math.radians(20))
    return ((x * c + y * s) / UNIT_PX, (-x * s + y * c) / UNIT_PX)


def unit_to_pixel(u, v, size):
    scale = size / 1024
    c, s = math.cos(math.radians(20)), math.sin(math.radians(20))
    x = (u * c - v * s) * UNIT_PX
    y = (u * s + v * c) * UNIT_PX
    return (int(size / 2 + x * scale), int(size / 2 + y * scale))


def linear(channel):
    channel /= 255
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def luminance(rgb):
    r, g, b = (linear(v) for v in rgb[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    hi, lo = sorted([luminance(a), luminance(b)], reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def lab(rgb):
    r, g, b = (linear(v) for v in rgb[:3])
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883

    def f(t):
        return t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116

    return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))


def delta_e(a, b):
    return math.dist(lab(a), lab(b))


def median_patch(image, u, v, radius=6):
    x0, y0 = unit_to_pixel(u, v, image.width)
    pixels = [image.getpixel((x, y)) for x in range(x0 - radius, x0 + radius + 1) for y in range(y0 - radius, y0 + radius + 1)]
    return tuple(sorted(p[i] for p in pixels)[len(pixels) // 2] for i in range(3))


def measure(path, erode=8):
    image = Image.open(path).convert("RGB")
    size = image.width
    mask = Image.new("L", image.size, 0)
    mask_pixels = mask.load()
    for py in range(size // 4, 3 * size // 4):
        for px in range(size // 4, 3 * size // 4):
            u, v = pixel_to_unit(px, py, size)
            if rounded_rect_contains(u, v, -10, -8) and rounded_rect_contains(u, v, 10, 8):
                mask_pixels[px, py] = 255
    inner = mask.filter(ImageFilter.MinFilter(2 * erode + 1))
    # Background samples: two points inside the icon but outside both shapes.
    bg_a = median_patch(image, 24.6, -34.6)
    bg_b = median_patch(image, -25.2, 34.3)
    background = tuple((a + b) // 2 for a, b in zip(bg_a, bg_b))
    background_l = lab(background)[0]
    gap = [image.getpixel((x, y)) for y in range(size) for x in range(size) if inner.getpixel((x, y))]
    deltas = sorted(delta_e(p, background) for p in gap)
    darker = sum(1 for p in gap if lab(p)[0] < background_l - 2.3)
    shape_a = median_patch(image, -20, -22)
    shape_b = median_patch(image, 20, 22)
    return {
        "background": background,
        "gap_de_p95": deltas[int(0.95 * len(deltas))],
        "gap_de_max": deltas[-1],
        "gap_darker": darker / len(gap),
        "a": shape_a,
        "b": shape_b,
        "a_vs_b_de": delta_e(shape_a, shape_b),
        "a_vs_b_cr": contrast(shape_a, shape_b),
    }


def render(icon, rendition, path, size=1024):
    subprocess.run(
        [ICTOOL, icon, "--export-image", "--output-file", path, "--platform", "iOS",
         "--rendition", rendition, "--width", str(size), "--height", str(size), "--scale", "1"],
        check=True, capture_output=True,
    )


def hex_color(rgb):
    return "#%02X%02X%02X" % rgb[:3]


def main():
    if not os.path.exists(ICTOOL):
        sys.exit(f"ictool not found at {ICTOOL}; install Xcode 27")
    os.makedirs(OUT, exist_ok=True)
    work = tempfile.mkdtemp(prefix="starling-icon-")
    try:
        print("| Appearance | Gap dE p95 | Gap dE max | Gap darker | A | B | A vs B dE | A vs B contrast |")
        print("|---|---|---|---|---|---|---|---|")
        tiles = []
        for rendition in RENDITIONS:
            full = os.path.join(work, rendition + ".png")
            render(ICON, rendition, full)
            m = measure(full)
            print(f"| {rendition} | {m['gap_de_p95']:.1f} | {m['gap_de_max']:.1f} | {m['gap_darker']:.1%} "
                  f"| {hex_color(m['a'])} | {hex_color(m['b'])} | {m['a_vs_b_de']:.1f} | {m['a_vs_b_cr']:.2f}:1 |")
            preview = Image.open(full).resize((512, 512), Image.LANCZOS)
            preview.save(os.path.join(OUT, FILE_NAMES[rendition]), optimize=True)
            tiles.append((rendition, preview))
        save_sheet(tiles, os.path.join(OUT, "icon-appearances.png"))

        print()
        print("| Shadow opacity | Gap dE p95 | Gap dE max | Gap darker |")
        print("|---|---|---|---|")
        crops = []
        for opacity in SHADOW_SWEEP:
            variant = os.path.join(work, f"shadow-{opacity}.icon")
            shutil.copytree(ICON, variant)
            manifest_path = os.path.join(variant, "icon.json")
            with open(manifest_path) as f:
                manifest = json.load(f)
            manifest["groups"][0]["shadow"]["opacity"] = opacity
            with open(manifest_path, "w") as f:
                json.dump(manifest, f)
            full = os.path.join(work, f"shadow-{opacity}.png")
            render(variant, "Default", full)
            m = measure(full)
            print(f"| {opacity} | {m['gap_de_p95']:.1f} | {m['gap_de_max']:.1f} | {m['gap_darker']:.1%} |")
            if opacity in (0.5, 0.2):
                crops.append((f"shadow {opacity}", Image.open(full).crop((262, 212, 762, 812)).resize((250, 300), Image.LANCZOS)))
        save_sheet(crops, os.path.join(OUT, "shadow-gap-0.5-vs-0.2.png"), columns=2)
    finally:
        shutil.rmtree(work)


def save_sheet(tiles, path, columns=3, pad=16, label=28):
    w, h = tiles[0][1].size
    rows = math.ceil(len(tiles) / columns)
    sheet = Image.new("RGB", (columns * (w + pad) + pad, rows * (h + pad + label) + pad), (128, 128, 128))
    draw = ImageDraw.Draw(sheet)
    for i, (name, tile) in enumerate(tiles):
        x = pad + (i % columns) * (w + pad)
        y = pad + (i // columns) * (h + pad + label)
        tile = tile.convert("RGBA")
        sheet.paste(tile, (x, y + label), tile)
        draw.text((x, y + 6), name, fill=(255, 255, 255))
    sheet.save(path, optimize=True)


if __name__ == "__main__":
    main()
