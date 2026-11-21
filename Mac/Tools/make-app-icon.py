#!/usr/bin/env python3
"""Builds Mac/Resources/Assets.xcassets/AppIcon.appiconset from docs/design/app-icon-v1-source.png.

macOS icons are not full-bleed: the artwork sits in an 824x824 rounded rectangle centred on a
1024x1024 transparent canvas (Apple's Big Sur+ icon grid), with a soft drop shadow. This script
makes that 1024 master with Pillow and then lets `sips` produce the standard sizes.

Usage (from the repo root):  python3 Mac/Tools/make-app-icon.py
"""
import json
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SOURCE = os.path.join(ROOT, "docs", "design", "app-icon-v1-source.png")
OUT = os.path.join(ROOT, "Mac", "Resources", "Assets.xcassets", "AppIcon.appiconset")

CANVAS = 1024
BODY = 824            # icon body size on the 1024 grid
RADIUS = 185          # corner radius of the body
SUPERSAMPLE = 4       # anti-aliased mask edges


def rounded_mask(size, radius):
    big = Image.new("L", (size * SUPERSAMPLE, size * SUPERSAMPLE), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        (0, 0, size * SUPERSAMPLE - 1, size * SUPERSAMPLE - 1), radius=radius * SUPERSAMPLE, fill=255)
    return big.resize((size, size), Image.LANCZOS)


def main():
    art = Image.open(SOURCE).convert("RGBA").resize((BODY, BODY), Image.LANCZOS)
    mask = rounded_mask(BODY, RADIUS)
    body = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 0))
    body.paste(art, (0, 0), mask)

    offset = (CANVAS - BODY) // 2
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    # Soft shadow under the body, like the system icons.
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_mask = Image.new("L", (CANVAS, CANVAS), 0)
    shadow_mask.paste(mask, (offset, offset + 10))
    shadow.putalpha(shadow_mask.point(lambda a: int(a * 0.30)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(body, (offset, offset))

    os.makedirs(OUT, exist_ok=True)
    master = os.path.join(OUT, "icon_512x512@2x.png")
    canvas.save(master)

    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            path = os.path.join(OUT, name)
            if path != master:
                subprocess.run(["sips", "-z", str(pixels), str(pixels), master, "--out", path],
                               check=True, stdout=subprocess.DEVNULL)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})

    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")
    print(f"wrote {len(images)} icon images to {OUT}")


if __name__ == "__main__":
    sys.exit(main())
