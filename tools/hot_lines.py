#!/usr/bin/env python3
"""Resolve the hottest Nimculus frames in a `sample` output to source lines.

Reading a symbol+offset out of a sample and reasoning about which statement it
lands in produced three wrong diagnoses in a row while chasing the scroll cost
against Zed. This resolves the recorded addresses with `atos` against the very
binary that was sampled, so the answer is the source line itself.

    tools/hot_lines.py sample.txt path/to/Nimculus
"""
import collections
import re
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    sample_path, binary = sys.argv[1], sys.argv[2]
    text = open(sample_path, errors="ignore").read()

    # The call tree comes before the binary list; the list carries the load
    # address atos needs to turn runtime addresses back into symbols.
    tree, _, images = text.partition("Binary Images")
    load = None
    for line in images.splitlines():
        if "Nimculus" in line:
            m = re.match(r"\s*(0x[0-9a-f]+)\s*-", line)
            if m:
                load = m.group(1)
                break
    if load is None:
        print("no load address for Nimculus in the sample", file=sys.stderr)
        return 1

    counts: collections.Counter = collections.Counter()
    for m in re.finditer(
        r"^[ +!:|]*(\d+) (.*?\(in Nimculus\).*?)\[(0x[0-9a-f]+)\]", tree, re.M
    ):
        counts[(m.group(3), m.group(2).strip())] += int(m.group(1))

    print(f"load address {load}")
    for (addr, sym), n in counts.most_common(20):
        try:
            resolved = subprocess.run(
                ["atos", "-o", binary, "-l", load, addr],
                capture_output=True, text=True, timeout=30,
            ).stdout.strip()
        except Exception as exc:  # atos missing or the binary has no symbols
            resolved = f"<atos failed: {exc}>"
        print(f"{n:5d}  {addr}  {resolved or sym}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
