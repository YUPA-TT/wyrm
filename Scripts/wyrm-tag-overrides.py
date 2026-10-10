#!/usr/bin/env python3
"""Wyrm tag customisation, applied after Scripts/prepare-original-engine.py.

1. Tag artwork: if Resources/WyrmTags/wyrm_tags.png exists, it replaces the
   prepared copy of the tag sheet (build-original-source/app/res/textures/
   wyrm_tags.png). The hash check in prepare-original-engine.py runs on the
   untouched SharedEngine/ source, so SHA256.json needs no change as long as
   SharedEngine/app/res/textures/wyrm_tags.png stays the original file.

2. Per-tag rope colour overrides. It rewrites the two rope colours
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
CUSTOM_SHEET = ROOT / "Resources/WyrmTags/wyrm_tags.png"
SHEET = ROOT / "build-original-source/app/res/textures/wyrm_tags.png"
SHEET_SIZE = (2048, 2048)  # TAG_ATLAS_WIDTH x TAG_ATLAS_HEIGHT in tag_table.h

OVERRIDES = {
    # pink rose (Wyrm tag): same rope colours as NTL tag #211
    100024: (0xFFDAF5, 0x8562D0),
}

HEX = r"0x[0-9a-fA-F]{6}"


def png_size(path):
    head = path.read_bytes()[:24]
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        sys.exit(f"{path} is not a PNG file")
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


if CUSTOM_SHEET.exists():
    if png_size(CUSTOM_SHEET) != SHEET_SIZE:
        sys.exit(f"{CUSTOM_SHEET} must be {SHEET_SIZE[0]}x{SHEET_SIZE[1]}, "
                 f"got {png_size(CUSTOM_SHEET)[0]}x{png_size(CUSTOM_SHEET)[1]}")
    SHEET.write_bytes(CUSTOM_SHEET.read_bytes())
    print(f"Replaced tag sheet with {CUSTOM_SHEET.relative_to(ROOT)}")


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
