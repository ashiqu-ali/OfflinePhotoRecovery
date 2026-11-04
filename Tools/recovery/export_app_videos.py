#!/usr/bin/env python3
"""Copies full video files out of the apps where a saved/edited screen recording could survive
(video editors, the Files app) into one folder, named with each video's pixel size so phone-screen
recordings are easy to spot, and dated from the backup's record.

    python3 -I export_app_videos.py <backup> <output folder> [--screen-only]
"""
import datetime
import hashlib
import os
import plistlib
import shutil
import sqlite3
import struct
import sys

APPS = {
    "AppDomain-com.frontrow.vlog": "VN video editor",
    "AppDomain-com.salehotaibiapps.blackholecut": "Video cutter",
    "AppDomainGroup-group.com.apple.FileProvider.LocalStorage": "Files app",
}


def dimensions(data):
    """Largest (w, h) from any 'tkhd' box found near the start or end of an MP4/MOV buffer."""
    best = (0, 0)
    start = 0
    while True:
        i = data.find(b"tkhd", start)
        if i < 0:
            break
        start = i + 4
        box = i - 4
        if box < 0:
            continue
        size = struct.unpack(">I", data[box:box + 4])[0]
        end = box + size
        if 92 <= size <= 200 and end <= len(data):
            w = struct.unpack(">I", data[end - 8:end - 4])[0] >> 16
            h = struct.unpack(">I", data[end - 4:end])[0] >> 16
            if 0 < w < 20000 and 0 < h < 20000 and w * h > best[0] * best[1]:
                best = (w, h)
    return best if best != (0, 0) else None


def dims_of(path):
    with open(path, "rb") as f:
        head = f.read(4_000_000)
        size = os.path.getsize(path)
        if size > 8_000_000:
            f.seek(size - 4_000_000)
            tail = f.read(4_000_000)
        else:
            tail = b""
    return dimensions(head) or dimensions(tail)


def mtime(blob):
    try:
        a = plistlib.loads(blob)
        return a["$objects"][a["$top"]["root"].data].get("LastModified")
    except Exception:
        return None


def main():
    backup, out = sys.argv[1], sys.argv[2]
    screen_only = "--screen-only" in sys.argv
    m = sqlite3.connect(f"file:{os.path.join(backup, 'Manifest.db')}?mode=ro&immutable=1", uri=True)
    rows = m.execute("SELECT fileID, domain, relativePath, file FROM Files WHERE flags=1 AND "
                     "(lower(relativePath) LIKE '%.mov' OR lower(relativePath) LIKE '%.mp4' OR lower(relativePath) LIKE '%.m4v')").fetchall()
    seen, counts, screen = set(), {}, 0
    for fid, domain, rel, blob in rows:
        if domain not in APPS:
            continue
        src = os.path.join(backup, fid[:2], fid)
        if not os.path.exists(src) or os.path.getsize(src) < 100_000:
            continue
        digest = hashlib.sha256(open(src, "rb").read()).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        dim = dims_of(src)
        is_screen = bool(dim and 0.44 <= min(dim) / max(dim) <= 0.52)
        if screen_only and not is_screen:
            continue
        app = APPS[domain]
        folder = os.path.join(out, app)
        os.makedirs(folder, exist_ok=True)
        ext = os.path.splitext(rel)[1].lower()
        base = os.path.splitext(os.path.basename(rel))[0][:40]
        tag = f"-{dim[0]}x{dim[1]}" if dim else ""
        if is_screen:
            tag += "-SCREEN"
            screen += 1
        dest = os.path.join(folder, f"{base}{tag}{ext}")
        n = 2
        while os.path.exists(dest):
            dest = os.path.join(folder, f"{base}{tag} ({n}){ext}")
            n += 1
        shutil.copyfile(src, dest)
        ts = mtime(blob)
        if ts:
            os.utime(dest, (ts, ts))
        counts[app] = counts.get(app, 0) + 1

    for app, n in sorted(counts.items()):
        print(f"  {n:4d}  {app}")
    print(f"Total videos copied: {sum(counts.values())}  (phone-screen-shaped, likely recordings: {screen})")


if __name__ == "__main__":
    main()
