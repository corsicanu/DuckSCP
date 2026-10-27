#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the app icon set and README logo from branding/logo-source.png.

- Crops the large icon, cuts it out with a rounded-rectangle mask (removes the
  blurred photo background), upscales with Lanczos, sharpens slightly, and centres
  it on Apple's 1024 px grid (824 px body) with a soft drop shadow.
- Writes branding/AppIcon.iconset (all sizes; turn into .icns with iconutil)
  and branding/logo.png (icon + wordmark for the README).
Usage: <python with Pillow> -I tools/make_icon.py
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "branding" / "logo-source.png"
OUT = ROOT / "branding"

src = Image.open(SRC).convert("RGB")

# Big icon body in the source (measured): left, top, right, bottom.
BODY = (88, 98, 648, 668)
body = src.crop(BODY)
w, h = body.size
scale = 4  # supersample the mask for smooth edges
mask = Image.new("L", (w * scale, h * scale), 0)
ImageDraw.Draw(mask).rounded_rectangle((7 * scale, 8 * scale, (w - 11) * scale, (h - 4) * scale),
                                       radius=int(0.225 * w * scale), fill=255)
mask = mask.resize((w, h), Image.LANCZOS)
body = body.convert("RGBA")
body.putalpha(mask)

SIZE, BODY_PX = 1024, 824
icon = body.resize((BODY_PX, int(BODY_PX * h / w)), Image.LANCZOS)
rgb = ImageEnhance.Contrast(icon.convert("RGB")).enhance(1.05)
rgb = ImageEnhance.Color(rgb).enhance(1.08)
rgb = rgb.filter(ImageFilter.UnsharpMask(radius=2, percent=60, threshold=2))
icon = Image.merge("RGBA", (*rgb.split(), icon.getchannel("A")))

canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
ox, oy = (SIZE - icon.width) // 2, (SIZE - icon.height) // 2
shadow_mask = icon.getchannel("A").point(lambda a: a * 0.45)
shadow.paste((0, 0, 0, 255), (ox, oy + 12), shadow_mask)
shadow = shadow.filter(ImageFilter.GaussianBlur(14))
canvas = Image.alpha_composite(canvas, shadow)
canvas.alpha_composite(icon, (ox, oy))
canvas.save(OUT / "AppIcon-1024.png")

iconset = OUT / "AppIcon.iconset"
iconset.mkdir(exist_ok=True)
for pt in (16, 32, 128, 256, 512):
    for mult in (1, 2):
        px = pt * mult
        img = canvas.resize((px, px), Image.LANCZOS)
        if px <= 64:  # tiny sizes lose detail; a touch more sharpening helps
            img = img.filter(ImageFilter.UnsharpMask(radius=1, percent=80, threshold=1))
        img.save(iconset / f"icon_{pt}x{pt}{'@2x' if mult == 2 else ''}.png")

# README logo: small round icon + "DuckSCP" wordmark with our own tagline.
# The source image's tagline names WinSCP (a third-party trademark), so it is painted
# over with the background colour and redrawn.
from PIL import ImageFont
TAGLINE = "SFTP, FTP & S3 client for macOS"
TAG_BOX = (900, 412, 1345, 462)      # old tagline area in the source
TAG_INK = (88, 88, 90)
wm = src.copy()
draw = ImageDraw.Draw(wm)
draw.rectangle(TAG_BOX, fill=(246, 246, 243))
size = 40
font = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size)
while draw.textlength(TAGLINE, font=font) > TAG_BOX[2] - TAG_BOX[0] - 8:
    size -= 1
    font = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size)
draw.text((905, 437), TAGLINE, font=font, fill=TAG_INK, anchor="lm")
WORDMARK = (682, 282, 1348, 488)
logo = wm.crop(WORDMARK)
logo = logo.resize((logo.width * 2, logo.height * 2), Image.LANCZOS)
logo = logo.filter(ImageFilter.UnsharpMask(radius=2, percent=70, threshold=2))
logo.save(OUT / "logo.png")
print("icon and logo written to", OUT)
