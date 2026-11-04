#!/usr/bin/env python3
"""Finds likely iPhone screenshots anywhere in an unencrypted iPhone backup (chat apps, Messages,
Notes attachments…) by image shape: iPhone-class screens are 9:19.5 (e.g. 1125 x 2436), and chat apps
shrink screenshots but keep that shape. Copies them, one folder per app, skipping exact duplicates.

    python3 -I screenshot_search.py <backup folder with Manifest.db> <output folder>
"""
import datetime
import hashlib
import os
import plistlib
import shutil
import sqlite3
import struct
import sys

RATIO_LOW, RATIO_HIGH = 0.455, 0.470   # short side / long side for 9:19.5 screens
MIN_LONG_SIDE = 600

APPS = {
    "net.whatsapp.WhatsApp": "WhatsApp", "net.whatsapp.WhatsAppSMB": "WhatsApp Business",
    "ph.telegra.Telegraph": "Telegram", "org.whispersystems.signal": "Signal",
    "com.burbn.instagram": "Instagram", "com.facebook.Messenger": "Messenger",
    "com.facebook.Facebook": "Facebook", "com.apple.notes": "Notes", "com.apple.mobilenotes": "Notes",
    "com.google.Gmail": "Gmail", "com.toyopagroup.picaboo": "Snapchat", "com.atebits.Tweetie2": "X (Twitter)",
    "com.linkedin.LinkedIn": "LinkedIn", "com.google.photos": "Google Photos",
}


def source(domain, path):
    if path.startswith("Library/SMS/Attachments"):
        return "Messages"
    if domain == "CameraRollDomain":
        return "Camera Roll"
    for prefix in ("AppDomainGroup-", "AppDomainPlugin-", "AppDomain-"):
        if domain.startswith(prefix):
            ident = domain[len(prefix):]
            for p in ("group.", "systemgroup."):
                if ident.startswith(p):
                    ident = ident[len(p):]
            for bundle, name in APPS.items():
                if ident == bundle or ident.startswith(bundle + "."):
                    return name
            return ident
    return domain


def dimensions(head):
    """(width, height, ext) from the first bytes of a PNG or JPEG, else None."""
    if head[:8] == b"\x89PNG\r\n\x1a\n" and len(head) >= 24:
        w, h = struct.unpack(">II", head[16:24])
        return w, h, "png"
    if head[:3] == b"\xff\xd8\xff":
        i = 2
        while i + 9 < len(head):
            if head[i] != 0xFF:
                i += 1
                continue
            marker = head[i + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            length = struct.unpack(">H", head[i + 2:i + 4])[0]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                h, w = struct.unpack(">HH", head[i + 5:i + 9])
                return w, h, "jpg"
            i += 2 + length
    return None


def mtime(blob):
    try:
        archive = plistlib.loads(blob)
        root = archive["$objects"][archive["$top"]["root"].data]
        return root.get("LastModified")
    except Exception:
        return None


def main():
    backup, out = sys.argv[1], sys.argv[2]
    db = sqlite3.connect(f"file:{os.path.join(backup, 'Manifest.db')}?mode=ro&immutable=1", uri=True)
    # The Camera Roll is the photo library itself (already on the phone, and its leftovers are
    # handled separately); Notes attachments come out with their notes.
    rows = db.execute("SELECT fileID, domain, relativePath, file FROM Files WHERE flags = 1 AND domain NOT IN "
                      "('CameraRollDomain', 'AppDomainGroup-group.com.apple.notes')").fetchall()
    db.close()

    seen, counts, checked = set(), {}, 0
    for file_id, domain, path, blob in rows:
        stored = os.path.join(backup, file_id[:2], file_id)
        try:
            with open(stored, "rb") as f:
                head = f.read(65536)
        except OSError:
            continue
        dims = dimensions(head)
        if not dims:
            continue
        checked += 1
        w, h, ext = dims
        short, long_ = sorted((w, h))
        if long_ < MIN_LONG_SIDE or not RATIO_LOW <= short / long_ <= RATIO_HIGH:
            continue
        digest = hashlib.sha256(open(stored, "rb").read()).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        app = source(domain, path)
        folder = os.path.join(out, app)
        os.makedirs(folder, exist_ok=True)
        base = os.path.splitext(os.path.basename(path))[0][:60] or file_id[:12]
        dest = os.path.join(folder, f"{base}-{w}x{h}.{ext}")
        n = 2
        while os.path.exists(dest):
            dest = os.path.join(folder, f"{base}-{w}x{h} ({n}).{ext}")
            n += 1
        shutil.copyfile(stored, dest)
        ts = mtime(blob)
        if ts:
            os.utime(dest, (ts, ts))
        counts[app] = counts.get(app, 0) + 1

    print(f"Images checked: {checked}")
    print(f"Likely screenshots found: {sum(counts.values())}")
    for app, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {n:5d}  {app}")


if __name__ == "__main__":
    main()
