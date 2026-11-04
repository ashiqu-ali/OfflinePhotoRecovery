#!/usr/bin/env python3
"""Builds a small fake iPhone backup (encrypted or not) for testing Offline Photo Finder.

It uses only the Python standard library plus the `openssl`, `sips` and (optionally) `ffmpeg`
commands, so it shares no code with the app it tests. Nothing here touches the network.

    python3 make_test_backup.py --out /tmp/testbackup --password test123
    python3 make_test_backup.py --out /tmp/plainbackup --unencrypted

Writes <out>/<UDID>/... plus <out>/expected.json listing the media files and their SHA-256.
"""
import argparse
import datetime
import hashlib
import json
import os
import plistlib
import shutil
import sqlite3
import struct
import subprocess
import tempfile
import zlib

OPENSSL = shutil.which("openssl") or "/usr/bin/openssl"
UDID = "00008150-000A1B2C3D4E5F60"


def aes_ecb_encrypt_block(key, block):
    return subprocess.run([OPENSSL, "enc", f"-aes-{len(key) * 8}-ecb", "-nopad", "-K", key.hex()],
                          input=block, capture_output=True, check=True).stdout


def aes_wrap(kek, key):
    """RFC 3394 key wrap."""
    n = len(key) // 8
    a = b"\xa6" * 8
    r = [key[i * 8:(i + 1) * 8] for i in range(n)]
    for j in range(6):
        for i in range(n):
            b = aes_ecb_encrypt_block(kek, a + r[i])
            t = n * j + i + 1
            a = (int.from_bytes(b[:8], "big") ^ t).to_bytes(8, "big")
            r[i] = b[8:]
    return a + b"".join(r)


def aes_cbc_encrypt(key, data):
    """AES-256-CBC, zero IV, PKCS#7 padding: how iOS stores files in encrypted backups."""
    return subprocess.run([OPENSSL, "enc", "-aes-256-cbc", "-K", key.hex(), "-iv", "00" * 16],
                          input=data, capture_output=True, check=True).stdout


def tlv(tag, value):
    if isinstance(value, int):
        value = struct.pack(">I", value)
    return tag.encode() + struct.pack(">I", len(value)) + value


def png(width, height, rgb):
    """A gradient image in the given base colour, so each test photo looks different."""
    raw = b"".join(
        b"\x00" + b"".join(bytes([min(255, rgb[0] + x // 3), min(255, rgb[1] + y // 3), rgb[2]]) for x in range(width))
        for y in range(height))

    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def convert(png_bytes, fmt, work, max_size=None):
    src = os.path.join(work, "src.png")
    dst = os.path.join(work, f"out.{fmt}")
    with open(src, "wb") as f:
        f.write(png_bytes)
    cmd = ["sips", "-s", "format", fmt, src, "--out", dst]
    if max_size:
        cmd[1:1] = ["-Z", str(max_size)]
    subprocess.run(cmd, capture_output=True, check=True)
    with open(dst, "rb") as f:
        return f.read()


def make_photos_sqlite(work, assets):
    """A minimal Photos.sqlite ZASSET table; assets is a list of (directory, filename, trashed_state)."""
    path = os.path.join(work, "Photos.sqlite")
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZDIRECTORY VARCHAR, ZFILENAME VARCHAR, "
               "ZTRASHEDSTATE INTEGER, ZUUID VARCHAR, ZCLOUDASSETGUID VARCHAR)")
    for i, (directory, filename, trashed) in enumerate(assets):
        db.execute("INSERT INTO ZASSET (ZDIRECTORY, ZFILENAME, ZTRASHEDSTATE, ZUUID) VALUES (?, ?, ?, ?)",
                   (directory, filename, trashed, f"UUID-{i:04d}"))
    db.commit()
    db.close()
    with open(path, "rb") as f:
        return f.read()


def make_video(work):
    if shutil.which("ffmpeg"):
        dst = os.path.join(work, "clip.mp4")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=15",
                        "-pix_fmt", "yuv420p", dst], check=True)
        with open(dst, "rb") as f:
            return f.read()
    return struct.pack(">I", 24) + b"ftypisom" + b"\x00" * 12 + os.urandom(4096)


def mbfile_blob(rel_path, size, cls, wrapped_key, mtime):
    root = {"$class": plistlib.UID(3), "RelativePath": plistlib.UID(2), "Size": size, "ProtectionClass": cls,
            "LastModified": mtime, "Birth": mtime, "LastStatusChange": mtime, "Mode": 0o100644,
            "InodeNumber": 1000 + size % 997, "UserID": 501, "GroupID": 501, "Flags": 0}
    objects = ["$null", root, rel_path,
               {"$classname": "MBFile", "$classes": ["MBFile", "NSObject"]},
               {"$classname": "NSMutableData", "$classes": ["NSMutableData", "NSData", "NSObject"]}]
    if wrapped_key is not None:
        root["EncryptionKey"] = plistlib.UID(5)
        objects.append({"$class": plistlib.UID(4), "NS.data": struct.pack("<I", cls) + wrapped_key})
    archive = {"$version": 100000, "$archiver": "NSKeyedArchiver", "$top": {"root": plistlib.UID(1)}, "$objects": objects}
    return plistlib.dumps(archive, fmt=plistlib.FMT_BINARY)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--password", default="test123")
    parser.add_argument("--unencrypted", action="store_true")
    parser.add_argument("--dpic", type=int, default=10_000_000, help="PBKDF2-SHA256 rounds (iOS uses 10,000,000)")
    args = parser.parse_args()
    encrypted = not args.unencrypted

    out = os.path.abspath(args.out)
    backup = os.path.join(out, UDID)
    if os.path.exists(backup):
        shutil.rmtree(backup)
    os.makedirs(backup)
    work = tempfile.mkdtemp()

    # Keybag: header plus one passcode-wrapped key per protection class.
    salt, dpsl = os.urandom(20), os.urandom(20)
    iterations = 10_000
    password_key = hashlib.pbkdf2_hmac("sha256", args.password.encode(), dpsl, args.dpic, 32)
    password_key = hashlib.pbkdf2_hmac("sha1", password_key, salt, iterations, 32)
    class_keys = {cls: os.urandom(32) for cls in range(1, 12)}
    bag = (tlv("VERS", 4) + tlv("TYPE", 1) + tlv("UUID", os.urandom(16)) + tlv("HMCK", os.urandom(40)) + tlv("WRAP", 0)
           + tlv("SALT", salt) + tlv("ITER", iterations) + tlv("DPWT", 1) + tlv("DPIC", args.dpic) + tlv("DPSL", dpsl))
    if encrypted:
        for cls, key in class_keys.items():
            bag += (tlv("UUID", os.urandom(16)) + tlv("CLAS", cls) + tlv("WRAP", 2) + tlv("KTYP", 0)
                    + tlv("WPKY", aes_wrap(password_key, key)))

    heic = convert(png(400, 300, (200, 40, 40)), "heic", work)
    jpeg = convert(png(400, 300, (40, 60, 200)), "jpeg", work)
    thumb = convert(png(400, 300, (40, 180, 60)), "jpeg", work, max_size=256)
    thumb_deleted = convert(png(400, 300, (10, 10, 200)), "jpeg", work, max_size=256)
    thumb_gone = convert(png(400, 300, (200, 10, 90)), "jpeg", work, max_size=256)
    # A minimal Photos library listing some photos as present and one as in Recently Deleted.
    photos_db = make_photos_sqlite(work, [
        ("DCIM/100APPLE", "IMG_0001.HEIC", 0),   # in the library
        ("DCIM/100APPLE", "IMG_0002.JPG", 0),    # in the library
        ("DCIM/100APPLE", "IMG_0003.JPG", 1),    # in Recently Deleted (thumbnail below)
    ])
    sms = convert(png(300, 400, (230, 120, 20)), "jpeg", work)
    whatsapp = convert(png(320, 320, (140, 40, 180)), "jpeg", work)
    telegram_png = png(200, 200, (220, 200, 20))
    video = make_video(work)
    audio = struct.pack(">I", 32) + b"ftypM4A " + b"\x00" * 20 + os.urandom(4000)

    wa = "AppDomainGroup-group.net.whatsapp.WhatsApp.shared"
    files = [  # (domain, path, content, protection class, is media, write to disk)
        ("CameraRollDomain", "Media/PhotoData/Photos.sqlite", photos_db, 3, False, True),
        ("CameraRollDomain", "Media/DCIM/100APPLE/IMG_0001.HEIC", heic, 3, True, True),
        ("CameraRollDomain", "Media/DCIM/100APPLE/IMG_0002.JPG", jpeg, 3, True, True),
        ("CameraRollDomain", "Media/PhotoData/Thumbnails/V2/DCIM/100APPLE/IMG_0003.JPG/5005.JPG", thumb_deleted, 3, True, True),
        ("CameraRollDomain", "Media/PhotoData/Thumbnails/V2/DCIM/101APPLE/IMG_7777.HEIC/5005.JPG", thumb_gone, 3, True, True),
        ("MediaDomain", "Library/SMS/Attachments/4a/10/8F0C1D2E-AAAA-BBBB-CCCC-1234567890AB/IMG_5521.jpeg", sms, 4, True, True),
        (wa, "Message/Media/919876543210@s.whatsapp.net/1/a/1a2b3c4d.jpg", whatsapp, 3, True, True),
        (wa, "Message/Media/919876543210@s.whatsapp.net/2/b/copy-of-0002.jpg", jpeg, 3, True, True),
        (wa, "Message/Media/919876543210@s.whatsapp.net/3/c/VID-20260101-WA0001.mp4", video, 3, True, True),
        ("AppDomain-ph.telegra.Telegraph", "Library/Caches/media/8823419234", telegram_png, 3, True, True),
        ("AppDomain-com.example.podcasts", "Library/Caches/audio123", audio, 3, False, True),
        ("HomeDomain", "Library/Preferences/com.apple.springboard.plist", plistlib.dumps({"a": 1}) * 40, 3, False, True),
        ("HomeDomain", "Library/Caches/tiny.jpg", b"\xff\xd8\xff" + os.urandom(400), 3, False, True),
        ("HomeDomain", "Library/Caches/blob.bin", os.urandom(4096), 3, False, True),
        ("AppDomain-com.burbn.instagram", "Library/Caches/missing.jpg", jpeg, 3, False, False),
    ]

    db_path = os.path.join(work, "Manifest.db")
    db = sqlite3.connect(db_path)
    # Real iOS backups store Manifest.db in WAL journal mode; reproduce that so the reader is tested against it.
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB)")
    db.execute("CREATE TABLE Properties (key TEXT PRIMARY KEY, value BLOB)")
    base_time = int(datetime.datetime(2026, 9, 1, 12, 0).timestamp())
    expected = []
    for index, (domain, path, content, cls, is_media, write) in enumerate(files):
        file_id = hashlib.sha1(f"{domain}-{path}".encode()).hexdigest()
        key = os.urandom(32)
        stored = aes_cbc_encrypt(key, content) if encrypted else content
        wrapped = aes_wrap(class_keys[cls], key) if encrypted else None
        mtime = base_time + index * 86400
        if write:
            os.makedirs(os.path.join(backup, file_id[:2]), exist_ok=True)
            with open(os.path.join(backup, file_id[:2], file_id), "wb") as f:
                f.write(stored)
        db.execute("INSERT INTO Files VALUES (?, ?, ?, 1, ?)",
                   (file_id, domain, path, mbfile_blob(path, len(content), cls, wrapped, mtime)))
        if is_media:
            expected.append({"domain": domain, "path": path, "sha256": hashlib.sha256(content).hexdigest()})
    dir_id = hashlib.sha1(b"CameraRollDomain-Media/DCIM/100APPLE").hexdigest()
    db.execute("INSERT INTO Files VALUES (?, 'CameraRollDomain', 'Media/DCIM/100APPLE', 2, ?)",
               (dir_id, mbfile_blob("Media/DCIM/100APPLE", 0, 0, None, base_time)))
    db.commit()
    # Checkpoint and drop WAL so the folder holds only Manifest.db (header still marks it WAL), as iOS ships it.
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.execute("PRAGMA journal_mode=DELETE")
    db.execute("PRAGMA journal_mode=WAL")
    db.commit()
    db.close()
    for sidecar in ("-wal", "-shm"):
        try:
            os.remove(db_path + sidecar)
        except FileNotFoundError:
            pass

    with open(db_path, "rb") as f:
        manifest_db = f.read()
    manifest = {"IsEncrypted": encrypted, "Version": "10.0", "Date": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
                "SystemDomainsVersion": "24.0", "WasPasscodeSet": True, "BackupKeyBag": bag, "Applications": {},
                "Lockdown": {"DeviceName": "Test iPhone", "ProductVersion": "26.1", "ProductType": "iPhone18,1",
                             "BuildVersion": "23B85", "UniqueDeviceID": UDID}}
    if encrypted:
        manifest_key = os.urandom(32)
        manifest["ManifestKey"] = struct.pack("<I", 4) + aes_wrap(class_keys[4], manifest_key)
        manifest_db = aes_cbc_encrypt(manifest_key, manifest_db)
    with open(os.path.join(backup, "Manifest.db"), "wb") as f:
        f.write(manifest_db)
    with open(os.path.join(backup, "Manifest.plist"), "wb") as f:
        plistlib.dump(manifest, f, fmt=plistlib.FMT_BINARY)
    with open(os.path.join(backup, "Info.plist"), "wb") as f:
        plistlib.dump({"Device Name": "Test iPhone", "Display Name": "Test iPhone", "Product Type": "iPhone18,1",
                       "Product Version": "26.1", "Last Backup Date": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
                       "Unique Identifier": UDID}, f)
    with open(os.path.join(backup, "Status.plist"), "wb") as f:
        plistlib.dump({"IsFullBackup": True, "SnapshotState": "finished", "Version": "3.3"}, f, fmt=plistlib.FMT_BINARY)
    with open(os.path.join(out, "expected.json"), "w") as f:
        json.dump(expected, f, indent=2)
    shutil.rmtree(work)
    print(f"Wrote {'encrypted' if encrypted else 'unencrypted'} test backup to {backup} ({len(expected)} media files)")


if __name__ == "__main__":
    main()
