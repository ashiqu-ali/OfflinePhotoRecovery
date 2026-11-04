#!/usr/bin/env python3
"""Non-interactive unlock using an already-recovered password (argv[3]). Reuses unlock_notes."""
import importlib.util
import os
import shutil
import sqlite3
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("un", os.path.join(here, "unlock_notes.py"))
un = importlib.util.module_from_spec(spec)
spec.loader.exec_module(un)

backup, out, password = sys.argv[1], sys.argv[2], sys.argv[3]
manifest = sqlite3.connect(f"file:{backup}/Manifest.db?mode=ro&immutable=1", uri=True)
files = {rel: fid for fid, rel in manifest.execute(
    "SELECT fileID, relativePath FROM Files WHERE flags=1 AND domain=?", (un.NOTES_DOMAIN,))}
stored = lambda fid: os.path.join(backup, fid[:2], fid)
work = tempfile.mkdtemp(prefix="unlock-")
try:
    shutil.copyfile(stored(files["NoteStore.sqlite"]), os.path.join(work, "NoteStore.sqlite"))
    db = sqlite3.connect(os.path.join(work, "NoteStore.sqlite"))
    db.row_factory = sqlite3.Row
    notes = db.execute("""SELECT o.*, d.ZDATA AS BODY, d.ZCRYPTOINITIALIZATIONVECTOR AS BODY_IV, d.ZCRYPTOTAG AS BODY_TAG
                          FROM ZICCLOUDSYNCINGOBJECT o JOIN ZICNOTEDATA d ON d.ZNOTE=o.Z_PK
                          WHERE o.ZISPASSWORDPROTECTED=1""").fetchall()
    done = 0
    for note in notes:
        key = un.object_key(password, note)
        body = key and un.gcm_decrypt(key, note["BODY_IV"], note["BODY_TAG"], note["BODY"] or b"")
        if body is None:
            print("  (a locked note did not open with this password)")
            continue
        un.export(db, note, key, password, body, files, stored, out)
        done += 1
    print(f"\nUnlocked {done} of {len(notes)} locked note(s) into:\n  {out}")
finally:
    shutil.rmtree(work, ignore_errors=True)
