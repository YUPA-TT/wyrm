#!/usr/bin/env python3
"""Per-tag rope colour overrides for Wyrm tags.

Run after Scripts/prepare-original-engine.py. It rewrites the two rope colours
(c1 = thick line, c2 = tapering overlay) of the listed tags in:
  - build-original-source/app/src/game/tag_table.h   (used in the arena)
  - SourcesShell/WyrmSkinCatalog.generated.swift     (used by the skin studio)
so the two always agree, without editing the hash-pinned engine sources.

OVERRIDES maps a tag's ntl id to (c1, c2) as 0xRRGGBB.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TABLE = ROOT / "build-original-source/app/src/game/tag_table.h"
CATALOG = ROOT / "SourcesShell/WyrmSkinCatalog.generated.swift"

OVERRIDES = {
    # pink rose (Wyrm tag): same rope colours as NTL tag #211
    100024: (0xFFDAF5, 0x8562D0),
}

HEX = r"0x[0-9a-fA-F]{6}"


def patch(path, pattern_for, replacement_for):
    text = path.read_text(encoding="utf-8-sig")
    for ntl, (c1, c2) in OVERRIDES.items():
        pattern = re.compile(pattern_for(ntl))
        text, count = pattern.subn(replacement_for(c1, c2), text)
        if count != 1:
            sys.exit(f"{path.name}: expected exactly one entry for ntl {ntl}, found {count}")
    path.write_text(text, encoding="utf-8")


# tag_table.h:  {w, h, bx, by, 0xC1, 0xC2, ntl, {uv...}},
patch(
    TABLE,
    lambda ntl: rf"{HEX}, {HEX}, ({ntl},)",
    lambda c1, c2: rf"0x{c1:06x}, 0x{c2:06x}, \1",
)

# WyrmSkinCatalog.generated.swift:  accentA: 0xC1, accentB: 0xC2, ntlID: ntl,
patch(
    CATALOG,
    lambda ntl: rf"accentA: {HEX}, accentB: {HEX}, (ntlID: {ntl},)",
    lambda c1, c2: rf"accentA: 0x{c1:06x}, accentB: 0x{c2:06x}, \1",
)

print(f"Applied rope colour overrides to {len(OVERRIDES)} tag(s)")
