"""Draws the app icon (an original tall-grass motif, no game art).

    python scripts/generate_icon.py
Writes App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"


def main() -> None:
    img = Image.new("RGB", (SIZE, SIZE))
    px = ImageDraw.Draw(img)
    # Dusk sky gradient.
    for y in range(SIZE):
        t = y / SIZE
        px.line([(0, y), (SIZE, y)], fill=(int(40 + 60 * t), int(40 + 90 * t), int(110 + 40 * t)))
    # Moon.
    px.ellipse([640, 150, 840, 350], fill=(250, 240, 200))
    # Blades of grass, back to front, darker to lighter.
    layers = [((24, 90, 50), 0.62, 11), ((38, 130, 64), 0.72, 9), ((70, 175, 80), 0.84, 7)]
    for colour, base_frac, count in layers:
        base = int(SIZE * base_frac)
        for i in range(count):
            x = (i + 0.5) * SIZE / count
            height = SIZE * (0.35 + 0.25 * math.sin(i * 2.3 + base_frac * 10) ** 2)
            lean = 90 * math.sin(i * 1.7 + base_frac * 5)
            w = SIZE / count * 0.55
            px.polygon([(x - w, SIZE), (x + w, SIZE), (x + lean, base - height + SIZE * 0.3)], fill=colour)
        px.rectangle([0, base + int(SIZE * 0.12), SIZE, SIZE], fill=colour)
    # Two eyes peeking out of the grass.
    for cx in (440, 560):
        px.ellipse([cx - 38, 700, cx + 38, 790], fill=(255, 255, 255))
        px.ellipse([cx - 16, 730, cx + 16, 780], fill=(20, 20, 30))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
