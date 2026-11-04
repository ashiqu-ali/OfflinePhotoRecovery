#!/usr/bin/env python3
"""Unlocks password-protected Apple Notes in an unencrypted iPhone backup, deleted ones included,
with the Notes password typed at a hidden prompt (never echoed, stored or logged).

    python3 -I unlock_notes.py <backup folder with Manifest.db> <output folder>

Scheme (Notes custom password): PBKDF2-SHA256(password, ZCRYPTOSALT, ZCRYPTOITERATIONCOUNT, 16 bytes)
unwraps ZCRYPTOWRAPPEDKEY (RFC 3394); that key decrypts the object with AES-128-GCM. Each object
(note, attachment, media) has its own salt and wrapped key, all derived from the same password.
"""
import ctypes
import datetime
import getpass
import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import zlib

NOTES_DOMAIN = "AppDomainGroup-group.com.apple.notes"
APPLE_EPOCH = 978307200
RFC3394_IV = bytes.fromhex("A6A6A6A6A6A6A6A6")
cc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")


def unwrap(kek, wrapped):
    out, n = ctypes.create_string_buffer(len(wrapped)), ctypes.c_size_t(len(wrapped) - 8)
    rc = cc.CCSymmetricKeyUnwrap(1, RFC3394_IV, 8, kek, len(kek), wrapped, len(wrapped), out, ctypes.byref(n))
    return out.raw[:n.value] if rc == 0 else None


def gcm_decrypt(key, iv, tag, data):
    out = ctypes.create_string_buffer(max(len(data), 1))
    rc = cc.CCCryptorGCMOneshotDecrypt(0, key, len(key), iv, len(iv), None, 0, data, len(data), out, tag, len(tag))
    return out.raw[:len(data)] if rc == 0 else None


def object_key(password, row):
    if not (row["ZCRYPTOSALT"] and row["ZCRYPTOWRAPPEDKEY"] and row["ZCRYPTOITERATIONCOUNT"]):
        return None
    kek = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), row["ZCRYPTOSALT"], row["ZCRYPTOITERATIONCOUNT"], 16)
    return unwrap(kek, row["ZCRYPTOWRAPPEDKEY"])


# --- protobuf (Apple Notes body: root.2 → .3 → .2) ------------------------------------------

def varint(buf, i):
    shift = value = 0
    while i < len(buf):
        b = buf[i]
        i += 1
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            return value, i
        shift += 7
    raise ValueError


def fields(buf):
    i = 0
    while i < len(buf):
        try:
            key, i = varint(buf, i)
            wt = key & 7
            if wt == 0:
                val, i = varint(buf, i)
            elif wt == 1:
                val, i = buf[i:i + 8], i + 8
            elif wt == 2:
                n, i = varint(buf, i)
                val, i = buf[i:i + n], i + n
            elif wt == 5:
                val, i = buf[i:i + 4], i + 4
            else:
                return
        except ValueError:
            return
        yield key >> 3, wt, val


def note_text(proto):
    for n1, w1, doc in fields(proto):
        if n1 == 2 and w1 == 2:
            for n2, w2, note in fields(doc):
                if n2 == 3 and w2 == 2:
                    for n3, w3, text in fields(note):
                        if n3 == 2 and w3 == 2:
                            return text.decode("utf-8", "replace").replace("￼", "[attachment]").strip()
    return ""


def gunzip(data):
    try:
        return zlib.decompress(data, 16 + zlib.MAX_WBITS) if data[:2] == b"\x1f\x8b" else data
    except zlib.error:
        return data


def when(value):
    return datetime.datetime.fromtimestamp(value + APPLE_EPOCH).strftime("%Y-%m-%d %H:%M") if value else ""


def safe_name(text, limit=50):
    name = re.sub(r"[^\w\- ]+", " ", text or "").strip()[:limit]
    return re.sub(r" {2,}", " ", name) or "Locked note"


def kind_of(data):
    if data[4:12] in (b"ftypheic", b"ftypheix", b"ftypmif1", b"ftyphevc"):
        return ".heic"
    if data[:3] == b"\xff\xd8\xff":
        return ".jpg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return ".png"
    if data[:4] == b"%PDF":
        return ".pdf"
    if data[4:8] == b"ftyp":
        return ".mov"
    return ".bin"


def main():
    backup, out = sys.argv[1], sys.argv[2]
    manifest = sqlite3.connect(f"file:{os.path.join(backup, 'Manifest.db')}?mode=ro&immutable=1", uri=True)
    files = {rel: fid for fid, rel in manifest.execute(
        "SELECT fileID, relativePath FROM Files WHERE flags = 1 AND domain = ?", (NOTES_DOMAIN,))}
    if "NoteStore.sqlite" not in files:
        sys.exit("No Notes database in this backup.")
    stored = lambda fid: os.path.join(backup, fid[:2], fid)
    work = tempfile.mkdtemp(prefix="unlock-")
    try:
        shutil.copyfile(stored(files["NoteStore.sqlite"]), os.path.join(work, "NoteStore.sqlite"))
        db = sqlite3.connect(os.path.join(work, "NoteStore.sqlite"))
        db.row_factory = sqlite3.Row
        notes = db.execute("""SELECT o.*, d.ZDATA AS BODY, d.ZCRYPTOINITIALIZATIONVECTOR AS BODY_IV, d.ZCRYPTOTAG AS BODY_TAG
                              FROM ZICCLOUDSYNCINGOBJECT o JOIN ZICNOTEDATA d ON d.ZNOTE = o.Z_PK
                              WHERE o.ZISPASSWORDPROTECTED = 1""").fetchall()
        if not notes:
            print("There are no locked notes in this backup.")
            return
        hints = sorted({r[0] for r in db.execute(
            "SELECT ZPASSWORDHINT FROM ZICCLOUDSYNCINGOBJECT WHERE ZPASSWORDHINT IS NOT NULL")})
        print(f"\nFound {len(notes)} locked note(s) in the backup.")
        for h in hints:
            print(f"Your Notes password hint: {h}")
        print("Type your Notes password (the one you used to lock notes, which may be an OLD password).")
        print("Nothing shows while you type. It is not saved anywhere.\n")

        remaining, attempts = list(notes), 0
        while remaining and attempts < 6:
            attempts += 1
            password = getpass.getpass("Notes password (or just press Return to stop): ")
            if not password:
                break
            still_locked = []
            for note in remaining:
                key = object_key(password, note)
                body = key and gcm_decrypt(key, note["BODY_IV"], note["BODY_TAG"], note["BODY"] or b"")
                if body is None:
                    still_locked.append(note)
                    continue
                export(db, note, key, password, body, files, stored, out)
            unlocked = len(remaining) - len(still_locked)
            remaining = still_locked
            if unlocked:
                print(f"  Unlocked {unlocked} note(s).")
            if remaining:
                print(f"  {len(remaining)} note(s) still locked: that password didn't open them. "
                      "Try another (an older Notes password, perhaps).")
            del password
        print(f"\nDone. {len(notes) - len(remaining)} of {len(notes)} locked note(s) unlocked into:\n  {out}")
    finally:
        shutil.rmtree(work, ignore_errors=True)


def export(db, note, key, password, body, files, stored, out):
    title, extra = note["ZTITLE1"], {}
    if note["ZENCRYPTEDVALUESJSON"] and note["ZCRYPTOINITIALIZATIONVECTOR"]:
        values = gcm_decrypt(key, note["ZCRYPTOINITIALIZATIONVECTOR"], note["ZCRYPTOTAG"], note["ZENCRYPTEDVALUESJSON"])
        if values:
            extra = json.loads(values)
            title = extra.get("title") or title
    text = note_text(gunzip(body))
    title = title or (text.splitlines()[0][:60] if text else "Locked note")
    day = when(note["ZMODIFICATIONDATE1"] or note["ZCREATIONDATE3"])[:10]
    folder = os.path.join(out, f"{safe_name(title)}" + (f" ({day})" if day else ""))
    os.makedirs(folder, exist_ok=True)
    state = "deleted" if note["ZMARKEDFORDELETION"] else "current"
    with open(os.path.join(folder, "note.txt"), "w", encoding="utf-8") as f:
        f.write(f"Title: {title}\nCreated: {when(note['ZCREATIONDATE3'])}\nModified: {when(note['ZMODIFICATIONDATE1'])}\n"
                f"Was: {state} locked note\n\n{text or '(no text)'}\n")

    saved = 0
    for att in db.execute("SELECT * FROM ZICCLOUDSYNCINGOBJECT WHERE ZNOTE = ?", (note["Z_PK"],)).fetchall():
        media = db.execute("SELECT * FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ?", (att["ZMEDIA"],)).fetchone() if att["ZMEDIA"] else None
        if not media:
            continue
        mkey = object_key(password, media)
        if not mkey:
            continue
        name = None
        if media["ZENCRYPTEDVALUESJSON"] and media["ZCRYPTOINITIALIZATIONVECTOR"]:
            values = gcm_decrypt(mkey, media["ZCRYPTOINITIALIZATIONVECTOR"], media["ZCRYPTOTAG"], media["ZENCRYPTEDVALUESJSON"])
            if values:
                name = json.loads(values).get("filename")
        for rel, fid in files.items():
            if not rel.startswith(f"Media/{media['ZIDENTIFIER']}/"):
                continue
            data = open(stored(fid), "rb").read()
            plain = data and gcm_decrypt(mkey, media["ZASSETCRYPTOINITIALIZATIONVECTOR"], media["ZASSETCRYPTOTAG"], data)
            if not plain:
                continue
            ext = kind_of(plain)
            base = os.path.splitext(name)[0] if name else f"photo {saved + 1}"
            with open(os.path.join(folder, safe_name(base, 40) + ext), "wb") as f:
                f.write(plain)
            saved += 1
    print(f"  · {title[:40]!r}: text {'recovered' if text else 'empty'}, {saved} photo(s)")


if __name__ == "__main__":
    main()
