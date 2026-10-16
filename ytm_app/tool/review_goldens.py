#!/usr/bin/env python3
"""List the goldens that changed and write before/after pairs you can look at.

Byte comparison is what `flutter test` does, and it is a terrible way to review
a visual change: it says "differs" and nothing else. This puts the committed
image and the working-tree image side by side in one PNG per golden, so a layout
change can actually be judged by eye before it is accepted.

    python tool/review_goldens.py          # only the ones that differ
    python tool/review_goldens.py --all    # also re-render the matching ones

Writes to  proof/golden_review/  (side-by-side PNGs + report.txt) and prints the
list of changed goldens. Exit code is 0 whether or not anything changed — this
reports, it does not gate. `flutter test` remains the gate.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover - a missing dev tool, reported clearly
    sys.exit(
        "Pillow is required to compose the comparison images.\n"
        "Install it with:  python -m pip install pillow"
    )

HERE = Path(__file__).resolve().parent
APP = HERE.parent  # ytm_app/
GOLDENS = APP / "test" / "golden" / "goldens"
OUT_DIR = APP / "proof" / "golden_review"

LABEL_HEIGHT = 28
GAP = 16
BAND = (24, 24, 27)
INK = (235, 235, 240)
INK_MUTED = (150, 150, 160)


def repo_root() -> Path:
    """The git root, so committed goldens can be read from it."""
    proc = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=APP,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"Not inside a git repository: {proc.stderr.strip()}")
    return Path(proc.stdout.strip())


def committed_image(root: Path, path: Path) -> Image.Image | None:
    """The version of `path` at HEAD, or None when it is not tracked yet."""
    rel = path.resolve().relative_to(root.resolve()).as_posix()
    proc = subprocess.run(
        ["git", "show", f"HEAD:{rel}"],
        cwd=root,
        capture_output=True,
    )
    if proc.returncode != 0 or not proc.stdout:
        return None
    import io

    return Image.open(io.BytesIO(proc.stdout)).convert("RGBA")


def labelled(image: Image.Image | None, label: str, size: tuple[int, int]) -> Image.Image:
    """One pane: a caption strip above the image, padded to a common canvas."""
    width, height = size
    pane = Image.new("RGBA", (width, height + LABEL_HEIGHT), BAND + (255,))
    draw = ImageDraw.Draw(pane)
    draw.text((8, 7), label, fill=INK if image is not None else INK_MUTED)

    if image is None:
        # Nothing committed yet: say so instead of showing an empty rectangle.
        draw.text((8, LABEL_HEIGHT + 8), "(not in HEAD)", fill=INK_MUTED)
        return pane

    pane.paste(image, (0, LABEL_HEIGHT))
    return pane


def side_by_side(before: Image.Image | None, after: Image.Image, headline: str) -> Image.Image:
    """before | after, on one canvas, with a headline above the pair."""
    panes = [before, after]
    width = max(p.size[0] for p in panes if p is not None)
    width = max(width, len(headline) * 7)
    height = max(p.size[1] for p in panes if p is not None)

    canvas = Image.new(
        "RGBA",
        (width * 2 + GAP, height + LABEL_HEIGHT * 2),
        (16, 16, 18, 255),
    )
    ImageDraw.Draw(canvas).text((0, 7), headline, fill=INK)

    canvas.paste(labelled(before, "before (HEAD)", (width, height)), (0, LABEL_HEIGHT))
    canvas.paste(
        labelled(after, "after (working tree)", (width, height)),
        (width + GAP, LABEL_HEIGHT),
    )
    return canvas


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--all",
        action="store_true",
        help="also re-render goldens whose bytes did not change",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=OUT_DIR,
        help=f"where to write the comparison images (default: {OUT_DIR})",
    )
    args = parser.parse_args()

    if not GOLDENS.is_dir():
        sys.exit(f"No goldens directory at {GOLDENS}")

    root = repo_root()
    goldens = sorted(GOLDENS.glob("*.png"))
    if not goldens:
        sys.exit(f"No golden PNGs in {GOLDENS}")

    changed: list[str] = []
    added: list[str] = []
    unchanged: list[str] = []
    rendered: list[Path] = []

    for path in goldens:
        name = path.name
        before = committed_image(root, path)
        after = Image.open(path).convert("RGBA")

        if before is None:
            status = "added"
            added.append(name)
        elif before.tobytes() != after.tobytes():
            status = "changed"
            changed.append(name)
        else:
            status = "unchanged"
            unchanged.append(name)

        if status == "unchanged" and not args.all:
            continue

        args.out.mkdir(parents=True, exist_ok=True)
        out_path = args.out / f"{path.stem}.before-after.png"
        side_by_side(before, after, f"{name}  [{status}]").save(out_path)
        rendered.append(out_path)

    report = [
        f"goldens checked : {len(goldens)}",
        f"changed         : {len(changed)}",
        f"added           : {len(added)}",
        f"unchanged       : {len(unchanged)}",
        "",
        "changed:",
        *[f"  {n}" for n in changed],
        "",
        "added (no committed version to compare against):",
        *[f"  {n}" for n in added],
        "",
        "comparison images written:",
        *[f"  {p}" for p in rendered],
    ]
    (args.out / "report.txt").parent.mkdir(parents=True, exist_ok=True)
    (args.out / "report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")

    print("\n".join(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
