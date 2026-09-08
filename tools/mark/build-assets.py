#!/usr/bin/env python3
"""Regenerate every derived brand asset from the two source SVGs.

Sources (edit these, never the outputs):
    docs/brand/source/lockup.svg   the Call: hawk head + HARK
    docs/brand/source/mark.svg     the head alone

Outputs:
    apps/Hark/Support/AppIcon.icns        macOS app icon (ivory mark on rufous)
    website/public/favicon.svg            same, 64px viewBox
    website/public/apple-touch-icon.png   180px, square (iOS applies the mask)
    website/public/og/card.png            1200x630 share card
    website/public/brand/lockup.svg       lockup, currentColor, for the site
    website/public/brand/mark.svg         mark, currentColor, for the site
    docs/assets/banner.svg                README banner, dark ground

Needs rsvg-convert, magick (ImageMagick 7) and iconutil (macOS). Colors come
from docs/brand.md §3.1; keep the two in step.

    python3 tools/mark/build-assets.py
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "docs/brand/source"
SITE = ROOT / "website/public"

CANVAS_LIGHT = "#faf8f3"
CANVAS_DARK = "#161412"
INK_LIGHT = "#1c1917"
INK_DARK = "#f3eee6"
INK_MUTED_LIGHT = "#625b54"
INK_MUTED_DARK = "#b3aa9e"
RUFOUS = "#b8432a"
FONT = "Helvetica Neue, Helvetica, Arial, sans-serif"


def load(name):
    """Return (inner group markup, width, height) of a source SVG."""
    s = (SRC / name).read_text()
    w, h = map(float, re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', s).groups())
    g = s[s.index("<g "):s.rindex("</g>") + 4]
    return g, w, h


def place(g, w, h, x, y, box_w, box_h, color):
    """Scale the group to fit box_w x box_h, centred at (x, y)."""
    k = min(box_w / w, box_h / h)
    tx = x - w * k / 2
    ty = y - h * k / 2
    return (f'<g transform="translate({tx:.2f} {ty:.2f}) scale({k:.5f})" '
            f'color="{color}">{g}</g>')


def svg(w, h, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
            f'width="{w}" height="{h}">\n{body}\n</svg>\n')


def run(*cmd):
    subprocess.run(cmd, check=True)


def main():
    for tool in ("rsvg-convert", "magick", "iconutil"):
        if shutil.which(tool) is None:
            sys.exit(f"missing {tool}")

    mark, mw, mh = load("mark.svg")
    lockup, lw, lh = load("lockup.svg")

    # Site copies of the sources, verbatim (currentColor, so CSS picks the ink).
    (SITE / "brand").mkdir(parents=True, exist_ok=True)
    for name in ("lockup.svg", "mark.svg"):
        shutil.copy(SRC / name, SITE / "brand" / name)

    # --- Icon artwork: ivory mark on a rufous rounded square. macOS convention
    # is the shape occupying ~80% of the canvas with transparent margin and a
    # corner radius of ~22.5% of the shape.
    def icon_svg(size, margin_ratio=0.1, rounded=True):
        m = size * margin_ratio
        box = size - 2 * m
        r = box * 0.225 if rounded else 0
        body = (f'<rect x="{m}" y="{m}" width="{box}" height="{box}" rx="{r}" '
                f'fill="{RUFOUS}"/>'
                + place(mark, mw, mh, size / 2, size / 2, box * 0.62, box * 0.62, INK_DARK))
        return svg(size, size, body)

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        (td / "icon.svg").write_text(icon_svg(1024))
        iconset = td / "AppIcon.iconset"
        iconset.mkdir()
        for pt in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = pt * scale
                name = f"icon_{pt}x{pt}" + ("@2x" if scale == 2 else "") + ".png"
                run("rsvg-convert", "-w", str(px), "-h", str(px),
                    str(td / "icon.svg"), "-o", str(iconset / name))
        out = ROOT / "apps/Hark/Support/AppIcon.icns"
        run("iconutil", "-c", "icns", str(iconset), "-o", str(out))
        print("wrote", out.relative_to(ROOT))

        # Favicon: same artwork, no transparent margin (browser tabs are small).
        (SITE / "favicon.svg").write_text(icon_svg(64, margin_ratio=0, rounded=True))
        print("wrote website/public/favicon.svg")

        # Touch icon: square, iOS rounds it.
        (td / "touch.svg").write_text(icon_svg(180, margin_ratio=0, rounded=False))
        run("rsvg-convert", "-w", "180", "-h", "180", str(td / "touch.svg"),
            "-o", str(SITE / "apple-touch-icon.png"))
        print("wrote website/public/apple-touch-icon.png")

        # --- OG card 1200x630: lockup top-left inside an 84px safe area,
        # tagline under it. Light canvas so it reads on both X and LinkedIn.
        W, H, M = 1200, 630, 84
        lock_w = 560
        lock_h = lock_w * lh / lw
        body = (f'<rect width="{W}" height="{H}" fill="{CANVAS_LIGHT}"/>'
                + place(lockup, lw, lh, M + lock_w / 2, M + lock_h / 2, lock_w, lock_h, INK_LIGHT)
                + f'<text x="{M}" y="{M + lock_h + 96}" font-family="{FONT}" font-size="54" '
                  f'font-weight="600" fill="{INK_LIGHT}" letter-spacing="-1">'
                  f'Hold a key. Speak. Release.</text>'
                + f'<text x="{M}" y="{M + lock_h + 150}" font-family="{FONT}" font-size="30" '
                  f'fill="{INK_MUTED_LIGHT}">Local dictation and meeting notes for your Mac. '
                  f'Nothing leaves it.</text>'
                + f'<rect x="{M}" y="{M + lock_h + 34}" width="96" height="6" fill="{RUFOUS}"/>')
        (td / "og.svg").write_text(svg(W, H, body))
        (SITE / "og").mkdir(exist_ok=True)
        run("rsvg-convert", "-w", str(W), "-h", str(H), str(td / "og.svg"),
            "-o", str(SITE / "og/card.png"))
        print("wrote website/public/og/card.png")

    # --- README banner: dark ground so it sits on GitHub light and dark alike.
    W, H = 760, 300
    lock_w = 420
    lock_h = lock_w * lh / lw
    body = (f'<rect width="{W}" height="{H}" rx="16" fill="{CANVAS_DARK}"/>'
            + place(lockup, lw, lh, W / 2, 120, lock_w, lock_h, INK_DARK)
            + f'<text x="{W / 2}" y="{H - 40}" text-anchor="middle" font-family="{FONT}" '
              f'font-size="20" fill="{INK_MUTED_DARK}">Hold a key. Speak. Release. '
              f'Nothing leaves your Mac.</text>')
    (ROOT / "docs/assets").mkdir(exist_ok=True)
    (ROOT / "docs/assets/banner.svg").write_text(svg(W, H, body))
    print("wrote docs/assets/banner.svg")


if __name__ == "__main__":
    main()
