"""Builds Resources/AppIcon.icns from Resources/AppIcon-source.png.

Fits the art to Apple's macOS icon template (an opaque 824 px body with ~185 px
corners on a 1024 px canvas); macOS 26 and later put icons of any other shape
on a gray plate. Run: uv run --with pillow scripts/make-icon.py
"""
import os, subprocess, tempfile
from PIL import Image, ImageDraw

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
src, out = os.path.join(root, "Resources/AppIcon-source.png"), os.path.join(root, "Resources/AppIcon.icns")
inset = 0.035  # crops inside the rounded square drawn in the source art
art = Image.open(src).convert("RGBA")
x0, y0, x1, y1 = art.getchannel("A").point(lambda a: 255 if a > 16 else 0).getbbox()
dx, dy = (x1 - x0) * inset, (y1 - y0) * inset
art = art.crop((int(x0 + dx), int(y0 + dy), int(x1 - dx), int(y1 - dy))).resize((824, 824), Image.LANCZOS)
# Apple's macOS icon template: an 824 px body with ~185 px corner radius, fully opaque.
mask = Image.new("L", (824 * 4, 824 * 4), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, 824 * 4 - 1, 824 * 4 - 1), radius=185 * 4, fill=255)
mask = mask.resize((824, 824), Image.LANCZOS)
art = Image.alpha_composite(Image.new("RGBA", art.size, (0, 0, 0, 255)), art)  # flatten translucency
art.putalpha(mask)
canvas = Image.new("RGBA", (1024, 1024)); canvas.paste(art, (100, 100), art)
iconset = os.path.join(tempfile.mkdtemp(), "AppIcon.iconset"); os.makedirs(iconset)
for s in (16, 32, 128, 256, 512):
    canvas.resize((s, s), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}.png")
    canvas.resize((s * 2, s * 2), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}@2x.png")
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
