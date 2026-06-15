#!/usr/bin/env python3
"""
Resize CTS map markers from 1024px source down to proper marker sizes,
and generate Flutter density buckets (1x / 2.0x / 3.0x).

Run from the passenger app root:
    python3 resize_markers.py

It reads the existing PNGs in assets/markers/, resizes, and writes:
    assets/markers/<name>.png          (1x)
    assets/markers/2.0x/<name>.png     (2x)
    assets/markers/3.0x/<name>.png     (3x)
"""
from PIL import Image
import os

ROOT = 'assets/markers'

# (filename, base_1x_size)  -- vehicles square; pins taller than wide
JOBS = [
    ('marker_motorbike.png', (64, 64)),
    ('marker_taxi.png',      (64, 64)),
    ('marker_minitruck.png', (64, 64)),
    ('marker_tricycle.png',  (64, 64)),   # processed if present
    ('pin_pickup.png',       (48, 64)),
    ('pin_dropoff.png',      (48, 64)),    # processed if present
]

os.makedirs(f'{ROOT}/2.0x', exist_ok=True)
os.makedirs(f'{ROOT}/3.0x', exist_ok=True)

for name, (w1, h1) in JOBS:
    src = f'{ROOT}/{name}'
    if not os.path.exists(src):
        print(f'skip (not found): {name}')
        continue
    img = Image.open(src).convert('RGBA')
    # autocrop to content first (trim transparent margins) so the marker fills the canvas
    bbox = img.split()[-1].getbbox()
    if bbox:
        img = img.crop(bbox)
    # for square (vehicle) markers, pad back to square so rotation pivots center
    is_vehicle = (w1 == h1)
    if is_vehicle:
        s = max(img.size)
        canvas = Image.new('RGBA', (s, s), (0, 0, 0, 0))
        canvas.paste(img, ((s - img.width) // 2, (s - img.height) // 2), img)
        img = canvas
    # write 3 densities
    for sub, mult in [('', 1), ('2.0x/', 2), ('3.0x/', 3)]:
        tw, th = w1 * mult, h1 * mult
        out = img.resize((tw, th), Image.LANCZOS)
        out.save(f'{ROOT}/{sub}{name}')
    print(f'done: {name}  -> {w1}x{h1} (1x), {w1*2}x{h1*2} (2x), {w1*3}x{h1*3} (3x)')

print('\nAll markers resized. Now: flutter pub get, then FULL restart.')