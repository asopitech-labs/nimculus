#!/usr/bin/env python3
"""Fail when the editor paints no text.

A bit diff alone cannot catch a blank editor: if the text disappears the window
fills with the background color, which matches Zed's background more often than
real glyphs do, so "identical pixels" goes UP while the app is broken. That is
exactly how a blank-editor regression slipped through once. Count ink instead.

Usage: ink_check.py <window.png> [min_ink_pixels]
"""
import sys
import numpy as np
from PIL import Image

EDITOR = (260, 190, 2300, 1450)  # retina crop inside the editor body


def main():
    path = sys.argv[1]
    minimum = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
    a = np.asarray(Image.open(path).convert("RGB").crop(EDITOR), dtype=np.int16)
    bg = np.median(a.reshape(-1, 3), axis=0)
    mask = np.abs(a - bg).max(axis=2) > 60
    ink = int(mask.sum())
    rows = np.where(mask.sum(axis=1) > 2)[0]
    print(f"editor ink pixels: {ink}")
    print(f"text rows found:   {len(rows)}")
    if ink < minimum:
        print(f"FAIL: fewer than {minimum} ink pixels — the editor is blank")
        return 1
    print("PASS: editor is painting text")
    return 0


if __name__ == "__main__":
    sys.exit(main())
