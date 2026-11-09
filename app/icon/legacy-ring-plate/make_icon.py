#!/usr/bin/env python3
"""Plate's retired app icon generator ("Ring Plate", the old DESIGN.md section 7, Concept A).

Retired: the app icon is now the E1 tomato linocut (app/icon/make_icons.py). This script is kept for
reference and writes only inside this folder: the SVG masters and Icon Composer layers here, and the
PNGs, README icon and contact sheet into out/.

Requires rsvg-convert (brew install librsvg) and Pillow.
Run: python3 -I app/icon/legacy-ring-plate/make_icon.py
"""
import json
import os
import subprocess
import tempfile

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
ICONSET = os.path.join(OUT, "Assets.xcassets", "AppIcon.appiconset")
CATALOG = os.path.join(OUT, "Assets.xcassets")
LAYERS = os.path.join(HERE, "layers")
SHEET = os.path.join(OUT, "icon-sheet.png")

S = 1024
C = 512  # canvas center

# ---- Geometry (1024 canvas) ----------------------------------------------
PLATE_R = 348      # rim disc (spec 330; larger for a more confident silhouette)
WELL_R = 206       # well (spec 214; leaves a wider white lip inside the arc)
ARC_R = 277        # arc midline, centered in the rim band (206..348)
ARC_W = 84         # arc stroke (spec 72; heavier so it holds at 29 pt)
ARC_SWEEP = 270    # degrees clockwise from 12 o'clock
CY = 506           # optical center: plate sits 6 px high to offset its shadow

# ---- Palettes -------------------------------------------------------------
LIGHT = dict(
    bg=[("0", "#FF9A52"), ("0.55", "#F26A1F"), ("1", "#D9480F")],
    shadow="#7A2400", shadow_op=0.30,
    rim_top="#FFFFFF", rim_bot="#FCEFE5",
    well=[("0", "#FFF8F1"), ("0.72", "#FFF1E6"), ("1", "#F7DCC7")],
    arc_a="#F56A1E", arc_b="#CE450C",
)
DARK = dict(
    bg=[("0", "#3A2416"), ("1", "#120B07")],
    shadow="#000000", shadow_op=0.45,
    rim_top="#4A4A4E", rim_bot="#2E2E31",
    well=[("0", "#1E1E20"), ("0.7", "#1A1A1C"), ("1", "#0F0F10")],
    arc_a="#FF9A55", arc_b="#FF7A2B",
)
TINT = dict(
    bg=[("0", "#000000"), ("1", "#000000")],
    shadow="#000000", shadow_op=0.0,
    rim_top="#8C8C8C", rim_bot="#8C8C8C",       # ~55% white
    well=[("0", "#404040"), ("1", "#404040")],  # ~25% white
    arc_a="#FFFFFF", arc_b="#FFFFFF",
)


def arc_path(r=ARC_R, sweep=ARC_SWEEP, cx=C, cy=CY):
    import math
    a0 = -90.0
    a1 = a0 + sweep
    x0 = cx + r * math.cos(math.radians(a0))
    y0 = cy + r * math.sin(math.radians(a0))
    x1 = cx + r * math.cos(math.radians(a1))
    y1 = cy + r * math.sin(math.radians(a1))
    large = 1 if sweep > 180 else 0
    return f"M {x0:.2f} {y0:.2f} A {r} {r} 0 {large} 1 {x1:.2f} {y1:.2f}"


def stops(lst):
    return "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in lst)


def icon_svg(p, size=S, rx=None, depth=True):
    """Full icon. rx rounds the canvas (README version only)."""
    bg_rect = f'<rect width="{S}" height="{S}"' + (f' rx="{rx}"' if rx else "") + ' fill="url(#bg)"/>'
    shadow = ""
    if depth and p["shadow_op"] > 0:
        shadow = (f'<circle cx="{C}" cy="{CY + 14}" r="{PLATE_R}" fill="{p["shadow"]}" '
                  f'opacity="{p["shadow_op"]}" filter="url(#soft)"/>')
    rim_fill = "url(#rim)" if depth else p["rim_top"]
    well_fill = "url(#well)" if depth else p["well"][min(1, len(p["well"]) - 1)][1]
    arc_stroke = "url(#arc)" if depth else p["arc_b"]
    clip = (f'<clipPath id="canvas"><rect width="{S}" height="{S}" rx="{rx}"/></clipPath>'
            if rx else "")
    g_open = '<g clip-path="url(#canvas)">' if rx else "<g>"
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {S} {S}">
  <defs>
    <linearGradient id="bg" x1="0.33" y1="0" x2="0.67" y2="1">{stops(p["bg"])}</linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{p["rim_top"]}"/><stop offset="1" stop-color="{p["rim_bot"]}"/>
    </linearGradient>
    <radialGradient id="well" cx="0.5" cy="0.56" r="0.54" fx="0.5" fy="0.58">{stops(p["well"])}</radialGradient>
    <linearGradient id="arc" gradientUnits="userSpaceOnUse" x1="{C + 200}" y1="{CY - 300}" x2="{C - 200}" y2="{CY + 300}">
      <stop offset="0" stop-color="{p["arc_a"]}"/><stop offset="1" stop-color="{p["arc_b"]}"/>
    </linearGradient>
    <filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="22"/></filter>
    {clip}
  </defs>
  {g_open}
    {bg_rect}
    {shadow}
    <circle cx="{C}" cy="{CY}" r="{PLATE_R}" fill="{rim_fill}"/>
    <circle cx="{C}" cy="{CY}" r="{WELL_R}" fill="{well_fill}"/>
    <path d="{arc_path()}" fill="none" stroke="{arc_stroke}" stroke-width="{ARC_W}" stroke-linecap="round"/>
  </g>
</svg>
'''


def layer_svgs():
    """Flat, unmasked layers for Icon Composer (no baked shadows or highlights)."""
    head = f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">'
    bg = (head + '<defs><linearGradient id="bg" x1="0.33" y1="0" x2="0.67" y2="1">'
          + stops(LIGHT["bg"]) + f'</linearGradient></defs><rect width="{S}" height="{S}" fill="url(#bg)"/></svg>\n')
    plate = (head + f'<circle cx="{C}" cy="{CY}" r="{PLATE_R}" fill="#FFFFFF"/>'
             f'<circle cx="{C}" cy="{CY}" r="{WELL_R}" fill="#FFF1E6"/></svg>\n')
    progress = (head + f'<path d="{arc_path()}" fill="none" stroke="#F26A1F" stroke-width="{ARC_W}" '
                'stroke-linecap="round"/></svg>\n')
    return {"background.svg": bg, "plate.svg": plate, "progress.svg": progress}


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def render(svg_path, px, out):
    subprocess.run(["rsvg-convert", "-w", str(px), "-h", str(px), "-o", out, svg_path], check=True)


def squircle_mask(px, scale=4):
    """iOS-style continuous-corner mask (superellipse approximation)."""
    import math
    n = 5.0
    big = px * scale
    pts = []
    for i in range(720):
        t = 2 * math.pi * i / 720
        ct, st = math.cos(t), math.sin(t)
        x = abs(ct) ** (2 / n) * (1 if ct >= 0 else -1)
        y = abs(st) ** (2 / n) * (1 if st >= 0 else -1)
        pts.append(((x + 1) / 2 * (big - 1), (y + 1) / 2 * (big - 1)))
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m.resize((px, px), Image.LANCZOS)


def contact_sheet(svgs, tmp):
    sizes = [1024, 180, 120, 87, 58, 40]
    disp = [360, 180, 120, 87, 58, 40]  # 1024 shown downscaled to fit
    walls = [("light", (236, 228, 220), (198, 214, 232)), ("dark", (28, 30, 40), (60, 40, 52))]
    pad = 40
    col_w = sum(disp) + pad * (len(disp) + 1)
    row_h = 360 + pad * 2
    rows = [(v, w) for v in svgs for w in walls]
    sheet = Image.new("RGB", (col_w, row_h * len(rows)), (0, 0, 0))
    ri = 0
    for name, svg in svgs:
        for wname, c0, c1 in walls:
            y0 = ri * row_h
            # wallpaper-like diagonal gradient
            band = Image.new("RGB", (col_w, row_h))
            d = ImageDraw.Draw(band)
            for x in range(col_w):
                t = x / col_w
                d.line([(x, 0), (x, row_h)], fill=tuple(int(c0[k] + (c1[k] - c0[k]) * t) for k in range(3)))
            sheet.paste(band, (0, y0))
            x = pad
            for px, dp in zip(sizes, disp):
                out = os.path.join(tmp, f"{name}-{px}.png")
                render(svg, px, out)
                im = Image.open(out).convert("RGBA")
                if dp != px:
                    im = im.resize((dp, dp), Image.LANCZOS)
                mask = squircle_mask(dp)
                if name == "tinted":
                    # emulate the system tint: luminance drives an orange tint
                    lum = im.convert("L")
                    tinted = Image.new("RGBA", im.size, (255, 150, 80, 255))
                    base = Image.new("RGBA", im.size, (20, 20, 22, 255))
                    im = Image.composite(tinted, base, lum)
                sheet.paste(im.convert("RGB"), (x, y0 + pad + (360 - dp)), mask)
                x += dp + pad
            ri += 1
    os.makedirs(os.path.dirname(SHEET), exist_ok=True)
    sheet.save(SHEET)


def main():
    masters = {
        "light": os.path.join(HERE, "icon-light.svg"),
        "dark": os.path.join(HERE, "icon-dark.svg"),
        "tinted": os.path.join(HERE, "icon-tinted.svg"),
    }
    write(masters["light"], icon_svg(LIGHT))
    write(masters["dark"], icon_svg(DARK))
    write(masters["tinted"], icon_svg(TINT, depth=False))
    for fn, text in layer_svgs().items():
        write(os.path.join(LAYERS, fn), text)

    # README icon: light icon with rounded corners (rx = 22.5%)
    write(os.path.join(OUT, "icon.svg"),
          icon_svg(LIGHT, size=64, rx=round(S * 0.225)).replace('width="64" height="64" ', ""))

    os.makedirs(ICONSET, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, fn in [("light", "AppIcon.png"), ("dark", "AppIcon-dark.png"), ("tinted", "AppIcon-tinted.png")]:
            raw = os.path.join(tmp, f"{name}.png")
            render(masters[name], S, raw)
            Image.open(raw).convert("RGB").save(os.path.join(ICONSET, fn), optimize=True)  # opaque, no alpha
        contact_sheet(list(masters.items()), tmp)

    contents = {
        "images": [
            {"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}],
             "filename": "AppIcon-dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}],
             "filename": "AppIcon-tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    write(os.path.join(ICONSET, "Contents.json"), json.dumps(contents, indent=2) + "\n")
    cat = os.path.join(CATALOG, "Contents.json")
    if not os.path.exists(cat):
        write(cat, json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print("done")


if __name__ == "__main__":
    main()
