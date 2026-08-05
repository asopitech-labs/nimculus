#!/bin/bash
# Full-window UI parity report: Nimculus vs Zed.
#
# Captures each window individually by CGWindowID (so overlapping windows do not
# corrupt the comparison), extracts the horizontal chrome bands and their painted
# colors from real pixels, and prints both side by side.
#
# Prerequisites: Screen Recording permission for the terminal, both apps running
# with the same document open in the same theme.
set -u
cd "$(dirname "$0")/.."

cat > /tmp/winlist.swift <<'SWIFT'
import CoreGraphics
import Foundation
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
  for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    guard (w[kCGWindowLayer as String] as? Int ?? -1) == 0 else { continue }
    let W = b["Width"] as? Double ?? 0, H = b["Height"] as? Double ?? 0
    guard W > 300, H > 200 else { continue }
    print("\(id)\t\(owner)\t\(Int(W))x\(Int(H))")
  }
}
SWIFT

ZED_ID=$(swift /tmp/winlist.swift 2>/dev/null | awk -F'\t' '$2=="Zed"{print $1; exit}')
NIM_ID=$(swift /tmp/winlist.swift 2>/dev/null | awk -F'\t' '$2=="Nimculus"{print $1; exit}')
[ -z "$ZED_ID" ] && { echo "Zed window not found"; exit 1; }
[ -z "$NIM_ID" ] && { echo "Nimculus window not found"; exit 1; }
echo "zed window=$ZED_ID  nimculus window=$NIM_ID"

screencapture -x -o -l"$ZED_ID" /tmp/win-zed.png || exit 1
screencapture -x -o -l"$NIM_ID" /tmp/win-nim.png || exit 1

python3 - <<'PY'
from PIL import Image
import numpy as np

def bands(path):
    a = np.asarray(Image.open(path).convert('RGB'), dtype=np.int16)
    h, w, _ = a.shape
    med = np.median(a, axis=1)
    raw = [0]
    for y in range(1, h):
        if np.abs(med[y] - med[y - 1]).max() > 6:
            raw.append(y)
    out = [raw[0]]
    for b in raw[1:]:
        if b - out[-1] > 8:
            out.append(b)
    return (w, h), [(b, tuple(int(v) for v in med[min(b + 3, h - 1)])) for b in out]

(zw, zh), zb = bands('/tmp/win-zed.png')
(nw, nh), nb = bands('/tmp/win-nim.png')
print(f"\nzed window {zw}x{zh}   nimculus window {nw}x{nh}   "
      f"{'SIZE MATCH' if (zw, zh) == (nw, nh) else 'SIZE MISMATCH'}\n")
print(f"{'#':>2}  {'Zed y(pt)':>10} {'color':>9}   {'Nim y(pt)':>10} {'color':>9}   verdict")
print("-" * 74)
for i in range(max(len(zb), len(nb))):
    z = zb[i] if i < len(zb) else None
    n = nb[i] if i < len(nb) else None
    zs = f"{z[0]/2:10.1f} #{z[1][0]:02x}{z[1][1]:02x}{z[1][2]:02x}" if z else " " * 20
    ns = f"{n[0]/2:10.1f} #{n[1][0]:02x}{n[1][1]:02x}{n[1][2]:02x}" if n else " " * 20
    ok = ""
    if z and n:
        dy = abs(z[0] - n[0]) / 2
        same = z[1] == n[1]
        ok = "PASS" if (dy <= 1 and same) else f"FAIL dy={dy:.1f}pt{'' if same else ' color'}"
    else:
        ok = "FAIL missing band"
    print(f"{i:>2}  {zs}   {ns}   {ok}")
PY
