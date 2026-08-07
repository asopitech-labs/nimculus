#!/bin/bash
# Per-window bit diff between Zed and Nimculus.
#
# Captures each window on its own with ScreenCaptureKit (SCContentFilter with
# desktopIndependentWindow), so an overlapping window never corrupts the
# comparison the way a full-screen grab does, then reports how many pixels are
# bit-identical and how far the rest deviate.
set -u
cd "$(dirname "$0")/.."
BIN=/tmp/nimculus-wincap
[ -x "$BIN" ] || swiftc -O tools/window_capture.swift -o "$BIN" || exit 1
"$BIN" Zed /tmp/bd-zed.png || exit 1
"$BIN" Nimculus /tmp/bd-nim.png || exit 1
python3 - <<'PY'
from PIL import Image
import numpy as np
z=np.asarray(Image.open('/tmp/bd-zed.png').convert('RGB'),dtype=np.int16)
n=np.asarray(Image.open('/tmp/bd-nim.png').convert('RGB'),dtype=np.int16)
h=min(z.shape[0],n.shape[0]); w=min(z.shape[1],n.shape[1]); z,n=z[:h,:w],n[:h,:w]
d=np.abs(z-n); m=d.max(axis=2)
print(f"window {w}x{h} retina = {w//2}x{h//2} pt")
print(f"  identical      {(m==0).mean()*100:6.2f}%")
print(f"  diff <= 2      {(m<=2).mean()*100:6.2f}%")
print(f"  diff <= 8      {(m<=8).mean()*100:6.2f}%")
print(f"  diff <= 32     {(m<=32).mean()*100:6.2f}%")
print(f"  diff  > 32     {(m>32).mean()*100:6.2f}%")
print(f"  mean abs diff  {d.mean():6.2f}")
# Retina row ranges of Zed's own chrome bands, measured from its window:
# 34pt title bar + rule, 31pt tab strip + rule, 44pt toolbar + rule, then the
# editor body down to the 745pt seam. Report against Zed's geometry, not ours,
# so a band number cannot silently describe the wrong strip of pixels.
for k,(a,b) in {'titlebar':(0,68),'tabbar':(70,132),'toolbar':(134,222),
                'editor':(224,1490),'seam':(1490,1522),
                'statusbar':(1522,h)}.items():
    s=m[a:b]
    print(f"  {k:11s} identical {(s==0).mean()*100:6.2f}%  >32 {(s>32).mean()*100:6.2f}%")
Image.fromarray(np.clip(m*3,0,255).astype('uint8')).save('/tmp/bd-heatmap.png')
PY
