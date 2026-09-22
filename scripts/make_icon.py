#!/usr/bin/env python3
"""Draw the PaperRush Bar app icon and write a macOS .iconset."""
from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path
import sys

S = 1024                      # master canvas
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.iconset")

# Apple's grid: a rounded square inset from the canvas, not edge-to-edge.
INSET = 100
RADIUS = 186
TOP = (46, 58, 140)           # indigo
BOTTOM = (28, 94, 178)        # blue
SAND = (245, 178, 62)         # amber
GLASS = (255, 255, 255)


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGB", (1, size), top)
    px = grad.load()
    for y in range(size):
        t = y / (size - 1)
        px[0, y] = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
    return grad.resize((size, size), Image.BILINEAR)


def rounded_mask(size, box, radius, supersample=4):
    m = Image.new("L", (size * supersample, size * supersample), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([c * supersample for c in box], radius=radius * supersample, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def hourglass(size):
    """The glass, drawn on its own transparent layer so it can be shadowed.

    Solid white bulbs with the sand inset inside them, rather than a stroked
    outline: at 16px a stroke turns to mush, and two stroked triangles read as
    an X instead of an hourglass.
    """
    ss = 4
    layer = Image.new("RGBA", (size * ss, size * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    cx = size / 2
    top_y, bot_y = 296, 728            # outer extent of the frame
    cap_h, cap_w = 38, 292
    half_w = 132                       # bulbs sit under the caps, never wider
    mid = (top_y + bot_y) / 2
    glass_top = top_y + cap_h - 4      # bulbs tuck under the caps
    glass_bot = bot_y - cap_h + 4
    border = 28                        # white left visible around the sand
    waist = 10                         # the bulbs meet in a short throat, not a point

    def S_(*xy):
        return [v * ss for v in xy]

    # Bulbs.
    d.polygon([*S_(cx - half_w, glass_top), *S_(cx + half_w, glass_top),
               *S_(cx + waist, mid), *S_(cx - waist, mid)], fill=GLASS + (255,))
    d.polygon([*S_(cx - waist, mid), *S_(cx + waist, mid),
               *S_(cx + half_w, glass_bot), *S_(cx - half_w, glass_bot)], fill=GLASS + (255,))

    def upper_w(y):   # half width of the sand cavity at height y in the top bulb
        return max(0.0, (half_w - border) * (mid - y) / (mid - glass_top))

    def lower_w(y):
        return max(0.0, (half_w - border) * (y - mid) / (glass_bot - mid))

    # Sand still to fall: a wedge resting in the upper bulb.
    fill_level = glass_top + border + (mid - glass_top - border) * 0.34
    d.polygon([*S_(cx - upper_w(fill_level), fill_level), *S_(cx + upper_w(fill_level), fill_level),
               *S_(cx + upper_w(mid - 6), mid - 6), *S_(cx - upper_w(mid - 6), mid - 6)],
              fill=SAND + (255,))

    # Sand already fallen: a mound on the floor of the lower bulb.
    floor = glass_bot - border * 0.55
    mound_top = floor - 104
    d.polygon([*S_(cx - lower_w(floor), floor), *S_(cx + lower_w(floor), floor),
               *S_(cx + lower_w(mound_top) * 0.72, mound_top),
               *S_(cx - lower_w(mound_top) * 0.72, mound_top)], fill=SAND + (255,))
    d.ellipse([*S_(cx - lower_w(mound_top) * 0.72, mound_top - 30),
               *S_(cx + lower_w(mound_top) * 0.72, mound_top + 30)], fill=SAND + (255,))

    # The falling grain.
    d.rounded_rectangle([*S_(cx - 10, mid - 4), *S_(cx + 10, mound_top - 6)],
                        radius=10 * ss, fill=SAND + (255,))

    # Caps, drawn last so they sit over the bulb corners.
    for y in (top_y, bot_y - cap_h):
        d.rounded_rectangle([*S_(cx - cap_w / 2, y), *S_(cx + cap_w / 2, y + cap_h)],
                            radius=(cap_h / 2) * ss, fill=GLASS + (255,))

    return layer.resize((size, size), Image.LANCZOS)


def build():
    base = vertical_gradient(S, TOP, BOTTOM).convert("RGBA")

    # A soft light from the top left keeps the plate from looking flat.
    sheen = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sheen).ellipse([-S * 0.35, -S * 0.75, S * 0.95, S * 0.45], fill=46)
    base = Image.composite(Image.new("RGBA", (S, S), (255, 255, 255, 255)), base,
                           sheen.filter(ImageFilter.GaussianBlur(S * 0.06)))

    glass = hourglass(S)

    # Drop shadow under the glass, so it reads on the blue.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 110), (0, 14), glass.split()[3])
    shadow = shadow.filter(ImageFilter.GaussianBlur(14))

    art = Image.alpha_composite(base, shadow)
    art = Image.alpha_composite(art, glass)

    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste(art, (0, 0), rounded_mask(S, (INSET, INSET, S - INSET, S - INSET), RADIUS))
    return icon


def main():
    icon = build()
    OUT.mkdir(parents=True, exist_ok=True)
    # The exact set `iconutil` expects.
    for px, names in {
        16: ["icon_16x16.png"], 32: ["icon_16x16@2x.png", "icon_32x32.png"],
        64: ["icon_32x32@2x.png"], 128: ["icon_128x128.png"],
        256: ["icon_128x128@2x.png", "icon_256x256.png"],
        512: ["icon_256x256@2x.png", "icon_512x512.png"],
        1024: ["icon_512x512@2x.png"],
    }.items():
        resized = icon.resize((px, px), Image.LANCZOS)
        for name in names:
            resized.save(OUT / name)
    icon.resize((512, 512), Image.LANCZOS).save(OUT.parent / "icon-preview.png")
    print(f"wrote {OUT} ({len(list(OUT.iterdir()))} files) + icon-preview.png")


if __name__ == "__main__":
    main()
