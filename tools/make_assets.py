#!/usr/bin/env python3
r"""
Generate listing art for Minimap Icon Bar from the shipped logo.

The in-game icon is `logo.tga` (the TOC IconTexture and the texture on the
toggle "M" button) — a near-white double-M mark on a transparent
background. This script treats it as the source of truth, never modifies
it, and composes the store/listing art around it so the published art
always matches what players see in-game.

Because the mark is white-on-transparent, the listing icons place it in a
dark action-bar slot (the same look the addon gives collected buttons),
which gives the white mark contrast and reinforces the addon's identity.

Outputs (all under assets/, which .pkgmeta ignores so none of it ships):
  assets/Icon-256.png, Icon-128.png, Icon-64.png  -- listing icons
  assets/Banner-1280.png, Banner-640.png          -- listing headers

Setup (one-time; Pillow in a local venv so we never touch system Python):
  python3 -m venv tools/.venv
  tools/.venv/bin/python -m pip install Pillow

Re-run after changing logo.tga:
  tools/.venv/bin/python tools/make_assets.py
"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")

# Palette: dark slate slot + a cool blue accent that matches the mark's tint.
SLOT_TOP = (26, 30, 40)
SLOT_BOT = (14, 16, 22)
ACCENT = (90, 150, 210)
FRAME = (150, 170, 200)
TITLE = "Minimap Icon Bar"
TAGLINE = "Your minimap buttons, in one tidy bar."
SUBTAG = "Masque / ElvUI aware  ·  per-character profiles"


def load_logo():
    return Image.open(os.path.join(ROOT, "logo.tga")).convert("RGBA")


def font(size, bold=True):
    candidates = (
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold
        else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold
        else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    )
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                pass
    return ImageFont.load_default()


def rounded_slot(size):
    """A dark action-bar-style slot: vertical gradient, inner glow, frame."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rad = int(size * 0.16)

    # Rounded-rect mask for the slot body.
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=rad, fill=255)

    # Vertical gradient body.
    grad = Image.new("RGBA", (size, size))
    gd = ImageDraw.Draw(grad)
    for y in range(size):
        t = y / size
        c = tuple(int(SLOT_TOP[i] + (SLOT_BOT[i] - SLOT_TOP[i]) * t) for i in range(3))
        gd.line([(0, y), (size, y)], fill=c + (255,))
    img.paste(grad, (0, 0), mask)

    # Soft accent glow in the centre.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gr = int(size * 0.36)
    ImageDraw.Draw(glow).ellipse(
        [size // 2 - gr, size // 2 - gr, size // 2 + gr, size // 2 + gr],
        fill=ACCENT + (60,))
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.08))
    img = Image.alpha_composite(img, Image.composite(
        glow, Image.new("RGBA", (size, size), (0, 0, 0, 0)), mask))

    # Frame edge.
    d = ImageDraw.Draw(img)
    fw = max(1, size // 40)
    d.rounded_rectangle([fw // 2, fw // 2, size - 1 - fw // 2, size - 1 - fw // 2],
                        radius=rad, outline=FRAME + (180,), width=fw)
    return img


def make_icon(logo, size):
    icon = rounded_slot(size)
    inset = int(size * 0.16)
    mark = logo.resize((size - 2 * inset, size - 2 * inset), Image.LANCZOS)
    icon.alpha_composite(mark, (inset, inset))
    return icon


def make_icons(logo):
    for size in (256, 128, 64):
        make_icon(logo, size).save(os.path.join(ASSETS, f"Icon-{size}.png"))


def make_banner(logo, w, h):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    d = ImageDraw.Draw(img)

    # Dark vertical gradient with a faint accent lift toward the bottom.
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)],
               fill=(int(14 + t * 10), int(17 + t * 16), int(23 + t * 28), 255))

    # Accent glow behind the icon.
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    cx, cy, gr = int(h * 0.5), h // 2, int(h * 0.5)
    ImageDraw.Draw(glow).ellipse([cx - gr, cy - gr, cx + gr, cy + gr],
                                 fill=ACCENT + (70,))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(h * 0.10)))

    # Icon (slot + mark) on the left, with a drop shadow.
    isz = int(h * 0.72)
    icon = make_icon(logo, isz)
    ix, iy = int(h * 0.14), (h - isz) // 2
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sh = Image.new("RGBA", icon.size, (0, 0, 0, 0))
    sh.paste((0, 0, 0, 150), (0, 0), icon)
    shadow.paste(sh, (ix + int(h * 0.015), iy + int(h * 0.025)), sh)
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(h * 0.02)))
    img.alpha_composite(icon, (ix, iy))

    # Title + tagline + feature subline.
    tx = ix + isz + int(h * 0.12)
    d = ImageDraw.Draw(img)
    d.text((tx, int(h * 0.22)), TITLE, font=font(int(h * 0.22)),
           fill=(238, 244, 248, 255))
    d.text((tx, int(h * 0.52)), TAGLINE, font=font(int(h * 0.11), bold=False),
           fill=(150, 178, 212, 255))
    d.text((tx, int(h * 0.70)), SUBTAG, font=font(int(h * 0.085), bold=False),
           fill=(120, 146, 178, 255))
    return img


def main():
    os.makedirs(ASSETS, exist_ok=True)
    logo = load_logo()
    make_icons(logo)
    make_banner(logo, 1280, 320).convert("RGB").save(
        os.path.join(ASSETS, "Banner-1280.png"))
    make_banner(logo, 640, 160).convert("RGB").save(
        os.path.join(ASSETS, "Banner-640.png"))
    print("wrote assets/Icon-256.png, Icon-128.png, Icon-64.png, "
          "Banner-1280.png, Banner-640.png")


if __name__ == "__main__":
    main()
