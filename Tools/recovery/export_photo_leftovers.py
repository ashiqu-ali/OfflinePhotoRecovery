#!/usr/bin/env python3
"""Copies leftovers of deleted Camera Roll items (found and dated by the earlier analysis, saved in
orphans.pkl) into the recovery folder. Files saved earlier under the same name are moved to their new
place rather than copied twice.

    python3 -I export_photo_leftovers.py <backup> <orphans.pkl> <recovery folder>
"""
import collections
import os
import pickle
import shutil
import struct
import sys

backup, pk, out = sys.argv[1:4]
orphans = pickle.load(open(pk, "rb"))
OLD = ("Screenshots (thumbnails)", "Photos (thumbnails)", "Videos (thumbnail frames)", "Edited versions (full size)")
existing = {}
for d in OLD:
    for root, _, names in os.walk(os.path.join(out, d)):
        for n in names:
            existing[n] = os.path.join(root, n)


def shape(data):
    """'screen' for phone-screen proportions (16:9 or 9:19.5), else 'photo'."""
    i = 2
    while i < len(data) - 9:
        if data[i] == 0xFF and data[i + 1] in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack(">HH", data[i + 5:i + 9])
            r = min(w, h) / max(w, h)
            return "screen" if 0.455 <= r <= 0.470 or 0.555 <= r <= 0.570 else "photo"
        i += 1
    return "photo"


counts = collections.Counter()
for key, o in sorted(orphans.items()):
    folder, img = key.split("/")[1:3]
    for kind in ("edit", "thumb"):
        if kind not in o:
            continue
        src = os.path.join(backup, o[kind][:2], o[kind])
        if kind == "edit":
            name = f"{folder}-{img}-edited.jpg"
            year = str(o["date"].year) if o["date"] else "unknown year"
            dest_dir = os.path.join(out, "Edited versions (full size)", year)
            label = f"edited {year} " + shape(open(src, "rb").read(200000))
        else:
            name = f"{folder}-{img}-thumbnail.jpg"
            dest_dir = os.path.join(out, {
                ".PNG": "Screenshots (thumbnails)",
                ".MP4": "Screen recordings and saved videos (thumbnail frames)",
                ".MOV": "Videos (thumbnail frames)",
            }.get(o.get("ext"), "Photos (thumbnails)"))
            label = os.path.basename(dest_dir)
        os.makedirs(dest_dir, exist_ok=True)
        dest = os.path.join(dest_dir, name)
        if name in existing and existing[name] != dest:
            shutil.move(existing[name], dest)
            counts[(label, "moved")] += 1
        elif not os.path.exists(dest):
            shutil.copyfile(src, dest)
            counts[(label, "new")] += 1
        else:
            counts[(label, "kept")] += 1
        if o["date"]:
            ts = o["date"].timestamp()
            os.utime(dest, (ts, ts))

for d in OLD:  # drop folders emptied by moves
    path = os.path.join(out, d)
    if os.path.isdir(path) and not any(files for _, _, files in os.walk(path)):
        shutil.rmtree(path)
for (label, how), n in sorted(counts.items()):
    print(f"{n:5d}  {how:5s}  {label}")
