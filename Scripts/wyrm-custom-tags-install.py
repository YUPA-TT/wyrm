#!/usr/bin/env python3
"""Installs Wyrm custom tags (your own picture as a tag, free rope colours).

Run in CI after Scripts/prepare-original-engine.py and before xcodegen:

    - run: python3 Scripts/prepare-original-engine.py
    - run: python3 Scripts/wyrm-custom-tags-install.py
    - run: xcodegen generate --spec original-engine.yml

The new files you add to the repo are
    SourcesOriginal/WyrmCustomTag.h
    SourcesOriginal/WyrmCustomTagBridge.h
    SourcesOriginal/AppleCustomTag.c
    SourcesShell/WyrmCustomTags.swift
This script hooks them into the existing code. It edits the CI checkout only
(and the prepared copy of the engine, which is not hash-checked), never the
hash-pinned SharedEngine/ sources. Every anchor it needs must match exactly
once, otherwise it stops with a message naming the file and the anchor.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

NEW_FILES = [
    "SourcesOriginal/WyrmCustomTag.h",
    "SourcesOriginal/WyrmCustomTagBridge.h",
    "SourcesOriginal/AppleCustomTag.c",
    "SourcesShell/WyrmCustomTags.swift",
]


def fail(message):
    sys.exit(f"wyrm-custom-tags-install: {message}")


def load(path):
    if not path.exists():
        fail(f"{path.relative_to(ROOT)} not found")
    return path.read_text(encoding="utf-8-sig").replace("\r\n", "\n")


def replace_once(text, old, new, where, required=True):
    count = text.count(old)
    if count != 1:
        message = f"{where}: expected one match of {old.strip()[:70]!r}, found {count}"
        if required:
            fail(message)
        print("warning:", message)
        return text
    return text.replace(old, new)


def patch(relative, edits, marker):
    path = ROOT / relative
    text = load(path)
    if marker in text:
        print(f"{relative}: already installed")
        return
    for old, new, required in edits:
        text = replace_once(text, old, new, relative, required)
    path.write_text(text, encoding="utf-8")
    print(f"{relative}: patched")


for name in NEW_FILES:
    if not (ROOT / name).exists():
        fail(f"{name} is missing: add the four custom tag files to the repo first")

# 1. The engine's tag drawing (prepared copy).
patch(
    "build-original-source/app/src/game/tags.c",
    [
        ('#include "tag_table.h"\n',
         '#include "tag_table.h"\n#include "WyrmCustomTag.h"\n', True),
        # the picture comes from its own texture
        ("  ImTextureRef texture = {NULL,\n"
         "                          (ImTextureID)(uintptr_t)env->usr->r->tags_descriptor};\n",
         "  ImTextureRef texture = {\n"
         "      NULL, (ImTextureID)(wyrm_custom_tag_drawing()\n"
         "                              ? wyrm_custom_tag_descriptor()\n"
         "                              : (uintptr_t)env->usr->r->tags_descriptor)};\n", True),
        # the arena: your own snake may wear the picture with no listed tag
        ("  if (!tags_valid(index)) return;\n  if (!slot) {\n",
         "  bool wyrm_custom = mine && wyrm_custom_tag_image_active();\n"
         "  if (!tags_valid(index) && !wyrm_custom) return;\n  if (!slot) {\n", True),
        ("  slot->frame = frame_number;\n"
         "  draw_tag(env, slot, TAG_TABLE + index, anchor_x, anchor_y, angle, scale, zoom,\n",
         "  slot->frame = frame_number;\n"
         "  tag_entry wyrm_entry;\n"
         "  const tag_entry* wyrm_tag = wyrm_custom_tag_entry(\n"
         "      mine, tags_valid(index) ? TAG_TABLE + index : NULL, &wyrm_entry);\n"
         "  if (!wyrm_tag) return;\n"
         "  draw_tag(env, slot, wyrm_tag, anchor_x, anchor_y, angle, scale, zoom,\n", True),
        # the skin editor's preview
        ("  if (!tags_valid(usrs->tag_index)) return;\n",
         "  if (!tags_valid(usrs->tag_index) && !wyrm_custom_tag_image_active()) return;\n", True),
        ("  draw_tag(env, slot, TAG_TABLE + usrs->tag_index,\n",
         "  tag_entry wyrm_entry;\n"
         "  const tag_entry* wyrm_tag = wyrm_custom_tag_entry(\n"
         "      true, tags_valid(usrs->tag_index) ? TAG_TABLE + usrs->tag_index : NULL,\n"
         "      &wyrm_entry);\n"
         "  if (!wyrm_tag) return;\n"
         "  draw_tag(env, slot, wyrm_tag,\n", True),
    ],
    "WyrmCustomTag.h",
)

# 2. Build the new C file into the engine library.
spec = ROOT / "original-engine.yml"
spec_text = load(spec)
if "AppleCustomTag.c" in spec_text:
    print("original-engine.yml: already installed")
else:
    pattern = re.compile(r"^(\s*)- path: SourcesOriginal/AppleSkinMailbox\.c\n", re.M)
    matches = pattern.findall(spec_text)
    if len(matches) != 1:
        fail(f"original-engine.yml: expected one AppleSkinMailbox.c source line, found {len(matches)}")
    spec_text = pattern.sub(
        lambda m: m.group(0) + f"{m.group(1)}- path: SourcesOriginal/AppleCustomTag.c\n", spec_text)
    spec.write_text(spec_text, encoding="utf-8")
    print("original-engine.yml: patched")

# 3. Apply the saved setting once a frame, from the existing skin hook.
patch(
    "SourcesOriginal/AppleSkinMailbox.c",
    [
        ('#include "user.h"\n', '#include "user.h"\n#include "WyrmCustomTag.h"\n', True),
        ("  if (!skin_mutex || !env) return;\n",
         "  if (!skin_mutex || !env) return;\n  WyrmCustomTagApply(env);\n", True),
    ],
    "WyrmCustomTagApply",
)

# 4. Let Swift see the two setters.
bridge = "SourcesShell/WyrmShell-Bridging-Header.h"
bridge_path = ROOT / bridge
bridge_text = load(bridge_path)
if "WyrmCustomTagBridge.h" in bridge_text:
    print(f"{bridge}: already installed")
else:
    bridge_path.write_text(bridge_text.rstrip("\n") + '\n#include "WyrmCustomTagBridge.h"\n',
                           encoding="utf-8")
    print(f"{bridge}: patched")

# 5. The "My tags" section above the built-in tag grid, and back to the listed
#    tag when one is chosen from it.
patch(
    "SourcesShell/WyrmSkinStudio.swift",
    [
        ('            WyrmSectionLabel("All tags")\n',
         '            WyrmCustomTagSection()\n            WyrmSectionLabel("All tags")\n', True),
        ("{ tag = -1; apply(tag: -1) }",
         "{ tag = -1; apply(tag: -1); WyrmCustomTagStore.shared.useOriginalTag() }", False),
        ("                        tag = item.id; apply(tag: item.id)\n",
         "                        tag = item.id; apply(tag: item.id)\n"
         "                        WyrmCustomTagStore.shared.useOriginalTag()\n", False),
    ],
    "WyrmCustomTagSection",
)

print("custom tags installed")
