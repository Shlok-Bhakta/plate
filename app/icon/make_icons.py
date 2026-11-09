#!/usr/bin/env python3
"""Plate app icons: the E1 "tomato linocut" primary and the seven alternates (DESIGN.md section 7).

From the hand-drawn masters in app/icon/concepts/ this writes:
  - concepts/E1-tomato-linocut/icon-dark.svg and icon-tinted.svg (recolors of icon.svg, same shapes)
  - Assets.xcassets/AppIcon.appiconset: E1 light (the master PNG as is), dark and tinted
  - Assets.xcassets/AppIcon-<ID>.appiconset for each alternate (light only)
  - Assets.xcassets/IconPreview-<ID>.imageset: 192 px thumbnails for Settings -> App Icon
    (E1's has a dark appearance too, so the thumbnail matches the home screen)
  - assets/icon.svg: the README icon, E1 with rx = 22.5%

Requires rsvg-convert (brew install librsvg) and Pillow. Run: python3 -I app/icon/make_icons.py
"""
import json
import os
import re
import shutil
import subprocess

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CONCEPTS = os.path.join(HERE, "concepts")
CATALOG = os.path.join(ROOT, "app", "Assets.xcassets")
PRIMARY = "E1-tomato-linocut"
# Alternate icon name suffix -> concept folder. Keep in sync with AppIcon.all in
# app/Sources/UI/Settings/AppIconSection.swift; the build passes every AppIcon-* set to actool.
ALTERNATES = {
    "D1": "D1-place-setting",
    "D2": "D2-plate-p",
    "D3": "D3-steam-bowl",
    "D4": "D4-tomato",
    "E2": "E2-market-bowl",
    "E3": "E3-paper-plate",
    "E4": "E4-steamy-bowl",
}
PREVIEW_PX = 192  # 64 pt @3x

# E1's palette, light -> dark. A deep cocoa ground; the speckles turn into faint lighter flecks; the
# tomato keeps its colors, with the calyx greens lifted a touch so they don't sink into the dark.
DARK = {
    "#F3E5CA": "#2A1E19",  # ground
    "#E6D2AE": "#3A2B23",  # speckles
    "#E7A72E": "#E7A72E",  # offset print (mustard)
    "#D9472B": "#DE4A2C",  # tomato
    "#A8321F": "#A8321F",  # carved ribs
    "#5B6B35": "#6A7C3D",  # calyx and stem
    "#93A66E": "#9DB077",  # leaf
}
# Tinted: a grayscale glyph on black. iOS maps luminance to the tint, so the tomato is the brightest
# mass, the calyx is white on it (carved like the ribs, but light), and the offset print sits well back.
TINTED = {
    "#F3E5CA": "#000000",
    "#E6D2AE": None,       # speckles dropped: they'd tint into noise
    "#E7A72E": "#4D4D4D",
    "#D9472B": "#B8B8B8",
    "#A8321F": "#6E6E6E",
    "#5B6B35": "#FFFFFF",
    "#93A66E": "#8A8A8A",
}


def recolor(svg, mapping):
    lines = []
    for line in svg.splitlines():
        m = re.search(r'fill="(#[0-9A-Fa-f]{6})"', line)
        if m and m.group(1).upper() in mapping:
            new = mapping[m.group(1).upper()]
            if new is None:
                continue
            line = line.replace(m.group(0), f'fill="{new}"')
        lines.append(line)
    return "\n".join(lines) + "\n"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def render(svg_path, px, out):
    subprocess.run(["rsvg-convert", "-w", str(px), "-h", str(px), svg_path, "-o", out], check=True)
    Image.open(out).convert("RGB").save(out, optimize=True)  # opaque, no alpha (App Store rule)


def thumb(src_png, out):
    Image.open(src_png).convert("RGB").resize((PREVIEW_PX, PREVIEW_PX), Image.LANCZOS).save(out, optimize=True)


def reset(path):
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path)


def write_json(path, obj):
    write(path, json.dumps(obj, indent=2) + "\n")


INFO = {"author": "xcode", "version": 1}


def icon_entry(filename, appearance=None):
    e = {"filename": filename, "idiom": "universal", "platform": "ios", "size": "1024x1024"}
    if appearance:
        e = {"appearances": [{"appearance": "luminosity", "value": appearance}], **e}
    return e


def main():
    e1 = os.path.join(CONCEPTS, PRIMARY)
    with open(os.path.join(e1, "icon.svg")) as f:
        light_svg = f.read()
    dark_svg_path = os.path.join(e1, "icon-dark.svg")
    tinted_svg_path = os.path.join(e1, "icon-tinted.svg")
    write(dark_svg_path, recolor(light_svg, DARK))
    write(tinted_svg_path, recolor(light_svg, TINTED))

    # Primary: the master PNG untouched, plus rendered dark and tinted.
    primary = os.path.join(CATALOG, "AppIcon.appiconset")
    reset(primary)
    shutil.copy(os.path.join(e1, "icon-1024.png"), os.path.join(primary, "AppIcon.png"))
    render(dark_svg_path, 1024, os.path.join(primary, "AppIcon-dark.png"))
    render(tinted_svg_path, 1024, os.path.join(primary, "AppIcon-tinted.png"))
    write_json(os.path.join(primary, "Contents.json"), {"images": [
        icon_entry("AppIcon.png"), icon_entry("AppIcon-dark.png", "dark"), icon_entry("AppIcon-tinted.png", "tinted"),
    ], "info": INFO})

    # Settings thumbnails.
    prev = os.path.join(CATALOG, "IconPreview-E1.imageset")
    reset(prev)
    thumb(os.path.join(primary, "AppIcon.png"), os.path.join(prev, "E1.png"))
    thumb(os.path.join(primary, "AppIcon-dark.png"), os.path.join(prev, "E1-dark.png"))
    write_json(os.path.join(prev, "Contents.json"), {"images": [
        {"filename": "E1.png", "idiom": "universal", "scale": "3x"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}],
         "filename": "E1-dark.png", "idiom": "universal", "scale": "3x"},
    ], "info": INFO})

    for key, folder in ALTERNATES.items():
        master = os.path.join(CONCEPTS, folder, "icon-1024.png")
        iconset = os.path.join(CATALOG, f"AppIcon-{key}.appiconset")
        reset(iconset)
        shutil.copy(master, os.path.join(iconset, f"AppIcon-{key}.png"))
        write_json(os.path.join(iconset, "Contents.json"),
                   {"images": [icon_entry(f"AppIcon-{key}.png")], "info": INFO})
        prev = os.path.join(CATALOG, f"IconPreview-{key}.imageset")
        reset(prev)
        thumb(master, os.path.join(prev, f"{key}.png"))
        write_json(os.path.join(prev, "Contents.json"),
                   {"images": [{"filename": f"{key}.png", "idiom": "universal", "scale": "3x"}], "info": INFO})

    # README icon: E1 clipped to a rounded square (rx = 22.5% of 1024).
    body = light_svg.split("\n", 1)[1].rsplit("</svg>", 1)[0].strip()
    write(os.path.join(ROOT, "assets", "icon.svg"),
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">\n'
          '<defs><clipPath id="r"><rect width="1024" height="1024" rx="230"/></clipPath></defs>\n'
          f'<g clip-path="url(#r)">\n{body}\n</g>\n</svg>\n')

    # Sanity: every master is opaque and 1024 px.
    for d in [primary] + [os.path.join(CATALOG, f"AppIcon-{k}.appiconset") for k in ALTERNATES]:
        for fn in os.listdir(d):
            if fn.endswith(".png"):
                im = Image.open(os.path.join(d, fn))
                assert im.size == (1024, 1024) and im.mode == "RGB", (fn, im.size, im.mode)
    print("done")


if __name__ == "__main__":
    main()
