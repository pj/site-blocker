#!/usr/bin/env python3
"""Generate the iOS app icon: a white padlock on a red field, 1024x1024, no alpha.

App Store icons must be a full-bleed square with no transparency and no pre-rounded corners
(iOS applies the rounded mask itself). Run:  python3 scripts/make-app-icon.py
Writes ios/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png.
"""
from pathlib import Path
from PIL import Image, ImageDraw

S = 1024
OUT = Path(__file__).resolve().parent.parent / "ios/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

img = Image.new("RGB", (S, S), (0, 0, 0))
d = ImageDraw.Draw(img)

# Vertical red gradient background (blocking = red, matching the Mac locked padlock).
top, bot = (0xE5, 0x48, 0x4D), (0xA8, 0x27, 0x2D)
for y in range(S):
    t = y / (S - 1)
    d.line([(0, y), (S, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bot)))

white = (255, 255, 255)
cx = S // 2

# Lock body: rounded rectangle, centered.
bw, bh = 470, 370
bx0, by0 = cx - bw // 2, 545
d.rounded_rectangle([bx0, by0, bx0 + bw, by0 + bh], radius=70, fill=white)

# Shackle: a thick arch (semicircular arc + two legs) rising out of the body top.
stroke = 74
r = 150                      # shackle radius (centerline of the stroke)
arc_cy = 455                 # center of the arc's circle
leg_bottom = by0 + 12        # where the legs meet the body
# Top semicircle: PIL angles go clockwise from 3 o'clock with y down, so 180→360 sweeps through
# 270 (the top), giving a dome. Box is a true square (2r × 2r) so it's a real semicircle.
d.arc([cx - r, arc_cy - r, cx + r, arc_cy + r], start=180, end=360, fill=white, width=stroke)
# Legs from the dome's ends straight down into the body.
d.line([(cx - r, arc_cy), (cx - r, leg_bottom)], fill=white, width=stroke)
d.line([(cx + r, arc_cy), (cx + r, leg_bottom)], fill=white, width=stroke)

# Keyhole punched in the body (background red).
red = (0xC4, 0x33, 0x39)
kx, ky = cx, by0 + bh // 2 - 20
d.ellipse([kx - 46, ky - 46, kx + 46, ky + 46], fill=red)
d.polygon([(kx - 26, ky + 20), (kx + 26, ky + 20), (kx + 46, ky + 150), (kx - 46, ky + 150)], fill=red)

OUT.parent.mkdir(parents=True, exist_ok=True)
img.save(OUT)
print(f"wrote {OUT} ({img.size[0]}x{img.size[1]})")
