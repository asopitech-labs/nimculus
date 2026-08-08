#!/usr/bin/env python3
"""Measure how far a capture pair actually scrolled, in pixels.

Two weaker guards let a broken build through while chasing scroll cost:

  * "the images differ" passed on a single changed pixel;
  * "at least 3% of pixels changed" passed at 7.1% while the document had not
    moved at all - a blinking caret and a scrollbar are enough.

A capped search range is its own trap: this tool reported 0px for a capture
pair that had scrolled from line 1 to line 163, because the real shift was far
outside the window it looked in. Search the whole image.

The only honest check is the displacement itself: find the vertical shift that
best aligns the two captures. Zed moved 708px over the same 40 events that
moved Nimculus 0px, and both of the earlier guards called that a pass.

    tools/scroll_shift.py before.png after.png [--min-pixels 200]

Exits non-zero when the shift is below --min-pixels.
"""
import sys

import numpy as np
from PIL import Image


def vertical_shift(before: str, after: str) -> tuple[int, float]:
    a = np.asarray(Image.open(before).convert("L"), dtype=np.float32)
    b = np.asarray(Image.open(after).convert("L"), dtype=np.float32)
    if a.shape != b.shape:
        raise SystemExit(f"captures differ in size: {a.shape} vs {b.shape}")
    height, width = a.shape
    # Compare the text column only. Side panels and chrome do not scroll and
    # would anchor the correlation at zero.
    x0, x1 = int(width * 0.10), int(width * 0.60)
    a, b = a[:, x0:x1], b[:, x0:x1]

    # Search the whole capture. A 1200px cap once reported 0px for a run that
    # had scrolled from line 1 to line 163 (~7800px): the correlation simply
    # never reached the real displacement, and the tool blamed the editor.
    best_shift, best_error = 0, float("inf")
    for shift in range(0, height - 200, 2):
        error = float(np.abs(a[shift:, :] - b[: height - shift, :]).mean())
        if error < best_error:
            best_shift, best_error = shift, error
    return best_shift, best_error


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    minimum = 200
    if "--min-pixels" in sys.argv:
        minimum = int(sys.argv[sys.argv.index("--min-pixels") + 1])

    shift, error = vertical_shift(args[0], args[1])
    print(f"vertical shift: {shift}px (residual {error:.1f})")
    if shift < minimum:
        print(
            f"FAIL: scrolled {shift}px, expected at least {minimum}px. "
            "The timing for this run is meaningless.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
