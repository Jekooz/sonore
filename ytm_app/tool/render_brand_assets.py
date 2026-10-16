#!/usr/bin/env python3
"""Render the Sonore brand rasters: the PNG app icons and the Windows .ico.

The SVGs in `assets/brand/` are the source of truth for the geometry. This
script draws that same geometry with Pillow, so no SVG renderer and no cairo is
needed anywhere in the build.

Every size is drawn on its own canvas at 4x supersampling and downscaled with
LANCZOS, which is what keeps the round caps and the tile's corner radius clean
down to 16px. The two smallest sizes use a simplified three-bar mark (wider
strokes, three bars) because the five-bar mark is not legible at 16-24px.

    python tool/render_brand_assets.py
"""

from __future__ import annotations

import io
import struct
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover - a missing dev tool, reported clearly
    sys.exit(
        "Pillow is required to render the brand rasters.\n"
        "Install it with:  python -m pip install pillow"
    )

HERE = Path(__file__).resolve().parent
APP = HERE.parent  # ytm_app/
BRAND = APP / "assets" / "brand"
ICO_PATH = APP / "windows" / "runner" / "resources" / "app_icon.ico"

# --- Geometry (512 canvas, from assets/brand/sonore-mark.svg) ---------------
CANVAS = 512
STROKE = 40
TILE_RADIUS = 112
# (centre x, y of first endpoint, y of second endpoint)
BARS: tuple[tuple[int, int, int], ...] = (
    (120, 206, 306),
    (188, 151, 361),
    (256, 106, 406),
    (324, 171, 341),
    (392, 226, 286),
)

# --- Simplified mark for the two smallest sizes ----------------------------
COMPACT_MAX = 24
COMPACT_STROKE = 60
COMPACT_BARS: tuple[tuple[int, int, int], ...] = (
    (170, 186, 326),
    (256, 116, 396),
    (342, 216, 296),
)

# A hairline is one 512th of the icon, never thinner than the supersampled grid
# allows; below that it simply is not drawn.
HAIRLINE_ALPHA = round(0.16 * 255)  # "white 16%" in sonore-icon.svg

SUPERSAMPLE = 4
SIZES: tuple[int, ...] = (16, 24, 32, 48, 64, 128, 256, 512, 1024)
ICO_SIZES: tuple[int, ...] = (16, 24, 32, 48, 64, 128, 256)

BLACK = (0, 0, 0, 255)
WHITE = (255, 255, 255, 255)


def geometry(size: int) -> tuple[tuple[tuple[int, int, int], ...], int]:
    """The bars and stroke width for a target size."""
    if size <= COMPACT_MAX:
        return COMPACT_BARS, COMPACT_STROKE
    return BARS, STROKE


def render_icon(size: int, tile: tuple, bar: tuple, hairline: bool) -> Image.Image:
    """The tile icon at `size`: rounded tile, optional hairline, then the mark.

    Drawn at [SUPERSAMPLE]x and downscaled through Pillow's premultiplied
    ("RGBa") mode, which stops the transparent corners from bleeding dark edges
    into the tile at small sizes.
    """
    bars, stroke = geometry(size)
    canvas = size * SUPERSAMPLE
    scale = canvas / CANVAS
    img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    box = (0.0, 0.0, canvas - 1.0, canvas - 1.0)
    draw.rounded_rectangle(box, radius=TILE_RADIUS * scale, fill=tile)

    if hairline:
        width = max(1, round(scale))
        inset = width / 2
        draw.rounded_rectangle(
            (box[0] + inset, box[1] + inset, box[2] - inset, box[3] - inset),
            radius=TILE_RADIUS * scale - inset,
            outline=(255, 255, 255, HAIRLINE_ALPHA),
            width=width,
        )

    for x, y1, y2 in bars:
        cx, t, b = x * scale, y1 * scale, y2 * scale
        radius = stroke * scale / 2
        draw.line((cx, t, cx, b), fill=bar, width=max(1, round(stroke * scale)))
        # Round caps: the SVG relies on stroke-linecap="round".
        draw.ellipse((cx - radius, t - radius, cx + radius, t + radius), fill=bar)
        draw.ellipse((cx - radius, b - radius, cx + radius, b + radius), fill=bar)

    return img.convert("RGBa").resize((size, size), Image.LANCZOS).convert("RGBA")


def dib_entry(img: Image.Image) -> bytes:
    """One .ico entry as an uncompressed 32-bit DIB (header + XOR + AND mask)."""
    w, h = img.size
    pixels = img.convert("RGBA").load()
    xor = bytearray()
    for y in range(h - 1, -1, -1):  # DIB rows are bottom-up
        for x in range(w):
            r, g, b, a = pixels[x, y]
            xor += bytes((b, g, r, a))
    mask_stride = ((w + 31) // 32) * 4  # 1bpp rows, padded to 4 bytes
    and_mask = bytes(mask_stride * h)  # zeroed: every pixel stays opaque
    header = struct.pack(
        "<IiiHHIIiiII",
        40,  # biSize
        w,
        h * 2,  # biHeight: XOR image stacked above the AND mask
        1,  # biPlanes
        32,  # biBitCount
        0,  # biCompression: BI_RGB
        len(xor) + len(and_mask),  # biSizeImage
        0,
        0,
        0,
        0,
    )
    return header + bytes(xor) + and_mask


def frame_bytes(img: Image.Image) -> bytes:
    """One .ico frame: raw DIB below 256px, PNG at 256px and above.

    That split is what the shell and Pillow both write, and it keeps a 256px
    frame at ~15KB instead of the ~270KB an uncompressed DIB costs.
    """
    if img.width >= 256:
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return buf.getvalue()
    return dib_entry(img)


def write_ico(path: Path, images: list[Image.Image]) -> None:
    """Pack `images` into a multi-size .ico.

    Pillow's own ICO writer resamples a single source image, which would throw
    away the simplified 16/24 geometry, so the entries are packed here instead.
    """
    images = sorted(images, key=lambda im: im.width)
    entries = bytearray()
    payload = bytearray()
    offset = 6 + 16 * len(images)
    for img in images:
        data = frame_bytes(img)
        w = 0 if img.width >= 256 else img.width
        h = 0 if img.height >= 256 else img.height
        entries += struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, len(data), offset)
        payload += data
        offset += len(data)
    path.write_bytes(struct.pack("<HHH", 0, 1, len(images)) + bytes(entries) + bytes(payload))


def main() -> int:
    BRAND.mkdir(parents=True, exist_ok=True)
    ico_images: list[Image.Image] = []

    for size in SIZES:
        icon = render_icon(size, BLACK, WHITE, hairline=True)
        out = BRAND / f"sonore-icon-{size}.png"
        icon.save(out, format="PNG")
        print(f"wrote {out.relative_to(APP)}")
        if size in ICO_SIZES:
            ico_images.append(icon)

    ICO_PATH.parent.mkdir(parents=True, exist_ok=True)
    write_ico(ICO_PATH, ico_images)
    print(f"wrote {ICO_PATH.relative_to(APP)}")

    # Read the .ico back so the entry list is proven, not assumed.
    with Image.open(ICO_PATH) as ico:
        print(f"app_icon.ico entries: {sorted(ico.info.get('sizes', []))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
