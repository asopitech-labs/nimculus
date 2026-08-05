#!/usr/bin/env python3
"""Measure UI parity between Zed and Nimculus from screenshots.

The acceptance criteria in docs/UI_PARITY_ACCEPTANCE.md are judged from real
pixels, not from "an equivalent element exists". This tool extracts the
structural numbers (line pitch, gutter width, text origin, chrome row heights)
and the actual painted colors from a screenshot region, so both apps can be
compared with the same method.

Usage:
  ui_parity.py capture <out.png>
  ui_parity.py measure <shot.png> <x> <y> <w> <h> [--label NAME] [--json out.json]
  ui_parity.py compare <a.json> <b.json>
"""

import json
import subprocess
import sys

import numpy as np
from PIL import Image


def capture(path):
    subprocess.run(["screencapture", "-x", path], check=True)
    im = Image.open(path)
    print(f"captured {path} {im.width}x{im.height}")


def _rgb(img):
    return np.asarray(img.convert("RGB"), dtype=np.int16)


def _row_is_uniform(row, tol=6):
    return int(row.max(axis=0).max() - row.min(axis=0).min()) <= tol


def horizontal_bands(a, tol=8):
    """Rows whose dominant color changes -> chrome band boundaries."""
    med = np.median(a, axis=1)
    bounds = []
    for y in range(1, len(med)):
        if np.abs(med[y] - med[y - 1]).max() > tol:
            bounds.append(y)
    return bounds


def text_rows(a, bg, thresh=60):
    """Rows containing glyph pixels (far from background)."""
    dist = np.abs(a - np.array(bg)).max(axis=2)
    counts = (dist > thresh).sum(axis=1)
    active = counts > max(2, counts.max() * 0.06) if counts.max() else counts > 1e9
    rows, run = [], None
    for y, on in enumerate(active):
        if on and run is None:
            run = y
        elif not on and run is not None:
            rows.append((run, y - 1))
            run = None
    if run is not None:
        rows.append((run, len(active) - 1))
    return rows


def line_pitch(rows):
    if len(rows) < 3:
        return None
    centers = [(a + b) / 2 for a, b in rows]
    deltas = [round(centers[i + 1] - centers[i], 2) for i in range(len(centers) - 1)]
    deltas = [d for d in deltas if d > 4]
    if not deltas:
        return None
    return float(np.median(deltas))


def column_profile(a, bg, thresh=60):
    dist = np.abs(a - np.array(bg)).max(axis=2)
    return (dist > thresh).sum(axis=0)


def first_ink_column(a, bg, thresh=60, min_rows=1):
    prof = column_profile(a, bg, thresh)
    for x, c in enumerate(prof):
        if c >= min_rows:
            return int(x)
    return None


def measure(path, box, label):
    x, y, w, h = box
    im = Image.open(path).convert("RGB")
    a = _rgb(im.crop((x, y, x + w, y + h)))
    scale = 2 if im.width > 2000 else 1  # Retina capture

    bg = [int(v) for v in np.median(a.reshape(-1, 3), axis=0)]
    rows = text_rows(a, bg)
    pitch = line_pitch(rows)
    ink_x = first_ink_column(a, bg)

    out = {
        "label": label,
        "region": {"x": x, "y": y, "w": w, "h": h},
        "capture_scale": scale,
        "background_rgb": bg,
        "background_hex": "#%02x%02x%02x" % tuple(bg),
        "line_pitch_px": pitch,
        "line_pitch_pt": round(pitch / scale, 2) if pitch else None,
        "text_row_count": len(rows),
        "first_ink_column_px": ink_x,
        "first_ink_column_pt": round(ink_x / scale, 2) if ink_x is not None else None,
        "band_boundaries_px": horizontal_bands(a)[:24],
    }
    return out


def compare(pa, pb):
    a = json.load(open(pa))
    b = json.load(open(pb))
    print(f"{'metric':28s} {a['label']:>16s} {b['label']:>16s}  delta")
    print("-" * 74)

    def row(name, ka, kb=None, fmt="{}"):
        va, vb = a.get(ka), b.get(kb or ka)
        d = ""
        if isinstance(va, (int, float)) and isinstance(vb, (int, float)):
            d = f"{vb - va:+.2f}"
        print(f"{name:28s} {str(va):>16s} {str(vb):>16s}  {d}")

    row("line pitch (pt)", "line_pitch_pt")
    row("first ink column (pt)", "first_ink_column_pt")
    row("background", "background_hex")
    same = a["background_hex"] == b["background_hex"]
    print(f"{'background match':28s} {'':>16s} {'':>16s}  {'YES' if same else 'NO'}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    if cmd == "capture":
        capture(sys.argv[2])
    elif cmd == "measure":
        path = sys.argv[2]
        box = tuple(int(v) for v in sys.argv[3:7])
        label = "region"
        out_json = None
        if "--label" in sys.argv:
            label = sys.argv[sys.argv.index("--label") + 1]
        if "--json" in sys.argv:
            out_json = sys.argv[sys.argv.index("--json") + 1]
        result = measure(path, box, label)
        print(json.dumps(result, indent=2))
        if out_json:
            json.dump(result, open(out_json, "w"), indent=2)
    elif cmd == "compare":
        compare(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
