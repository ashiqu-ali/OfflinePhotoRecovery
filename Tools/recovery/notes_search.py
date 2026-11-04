#!/usr/bin/env python3
"""Searches an unencrypted iPhone backup for deleted Apple Notes: notes still in the database after
deletion (Recently Deleted, or deleted from there but not yet erased), with their photos, scans and
drawings, plus text left behind by erased notes (gzip streams carved from the database file and WAL).

    python3 -I notes_search.py <backup folder with Manifest.db> <output folder>

Read-only on the backup. Writes one folder per deleted note, fragments, and a summary.txt.
"""
import datetime
import hashlib
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import zlib

NOTES_DOMAIN = "AppDomainGroup-group.com.apple.notes"
APPLE_EPOCH = 978307200  # 2001-01-01
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".gif", ".tiff", ".pdf", ".mov", ".mp4", ".m4a"}


def backup_file(backup, file_id):
    return os.path.join(backup, file_id[:2], file_id)


def manifest_rows(backup, where, args=()):
    db = sqlite3.connect(f"file:{os.path.join(backup, 'Manifest.db')}?mode=ro&immutable=1", uri=True)
    try:
        return db.execute(f"SELECT fileID, domain, relativePath FROM Files WHERE flags = 1 AND {where}", args).fetchall()
    finally:
        db.close()


# --- protobuf (just enough for Apple Notes) -------------------------------------------------

def varint(buf, i):
    shift = value = 0
    while i < len(buf):
        b = buf[i]
        i += 1
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            return value, i
        shift += 7
        if shift > 63:
            break
    raise ValueError("bad varint")


def fields(buf):
    """Yields (field number, wire type, value) for one protobuf message; stops quietly at damage."""
    i = 0
    while i < len(buf):
        try:
            key, i = varint(buf, i)
            num, wt = key >> 3, key & 7
            if wt == 0:
                val, i = varint(buf, i)
            elif wt == 1:
                val, i = buf[i:i + 8], i + 8
            elif wt == 2:
                n, i = varint(buf, i)
                if n > len(buf) - i:
                    val, i = buf[i:], len(buf)  # truncated (carved fragment): keep what is there
                else:
                    val, i = buf[i:i + n], i + n
            elif wt == 5:
                val, i = buf[i:i + 4], i + 4
            else:
                return
        except ValueError:
            return
        if num == 0:
            return
        yield num, wt, val


def note_text(proto):
    """Apple Notes body: root.2 (document) → .3 (note) → .2 (text). Falls back to the longest string."""
    for n1, w1, doc in fields(proto):
        if n1 == 2 and w1 == 2:
            for n2, w2, note in fields(doc):
                if n2 == 3 and w2 == 2:
                    for n3, w3, text in fields(note):
                        if n3 == 2 and w3 == 2:
                            return text.decode("utf-8", "replace")
    best = b""
    stack = [proto]
    while stack:
        for _, wt, val in fields(stack.pop()):
            if wt == 2:
                try:
                    s = val.decode("utf-8")
                    if len(val) > len(best) and sum(c.isprintable() or c in "\n\t￼" for c in s) > 0.9 * len(s):
                        best = val
                except UnicodeDecodeError:
                    pass
                stack.append(val)
    return best.decode("utf-8", "replace") if len(best) >= 8 else ""


UUID = re.compile(r"^[0-9A-Fa-f-]{36}$")


def table_text(proto):
    """Cell text of a Notes table (a CRDT document): every nested note body, in stored order."""
    cells, stack = [], [proto]
    while stack:
        buf = stack.pop()
        for num, wt, val in fields(buf):
            if wt != 2:
                continue
            text = note_text(val) if num == 3 else ""
            if text and not UUID.match(text) and text not in cells and len(fields_list(val)) < 50:
                cells.append(text.strip())
            stack.append(val)
    return [c for c in cells if c]


def fields_list(buf):
    return list(fields(buf))


def gunzip(data):
    """Decompresses as much of a gzip stream as possible (carved streams are often cut short)."""
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    out = b""
    try:
        for i in range(0, len(data), 512):
            out += d.decompress(data[i:i + 512])
            if d.eof:
                break
    except zlib.error:
        pass
    return out


def clean(text):
    return text.replace("￼", "[attachment]").strip()


# --- live database ----------------------------------------------------------------------------

def columns(db, table):
    return {r[1] for r in db.execute(f"PRAGMA table_info({table})")}


def first(cols, *names):
    return next((n for n in names if n in cols), None)


def col(cols, name):
    return name if name in cols else "NULL"


def live_notes(db_path):
    db = sqlite3.connect(db_path)
    obj_cols = columns(db, "ZICCLOUDSYNCINGOBJECT")
    title = first(obj_cols, "ZTITLE1", "ZTITLE")
    created = first(obj_cols, "ZCREATIONDATE3", "ZCREATIONDATE1", "ZCREATIONDATE")
    modified = first(obj_cols, "ZMODIFICATIONDATE1", "ZMODIFICATIONDATE")
    folder_title = first(obj_cols, "ZTITLE2", "ZTITLE")

    trash_folders = set()
    if "ZFOLDERTYPE" in obj_cols:
        trash_folders = {r[0] for r in db.execute("SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT WHERE ZFOLDERTYPE = 1")}
    folder_names = {}
    if folder_title:
        folder_names = {r[0]: r[1] for r in db.execute(
            f"SELECT Z_PK, {folder_title} FROM ZICCLOUDSYNCINGOBJECT WHERE {folder_title} IS NOT NULL")}

    select = ", ".join(c or "NULL" for c in (title, created, modified))
    select += f", {col(obj_cols, 'ZFOLDER')}, {col(obj_cols, 'ZMARKEDFORDELETION')}, {col(obj_cols, 'ZSNIPPET')}, {col(obj_cols, 'ZISPASSWORDPROTECTED')}"
    notes = []
    for note_pk, data in db.execute("SELECT ZNOTE, ZDATA FROM ZICNOTEDATA WHERE ZNOTE IS NOT NULL"):
        row = db.execute(f"SELECT {select} FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ?", (note_pk,)).fetchone()
        row = row or (None,) * 7
        locked = bool(row[6])
        text = "" if locked or not data else clean(note_text(gunzip(data) if data[:2] == b"\x1f\x8b" else data))
        notes.append({
            "pk": note_pk,
            "title": row[0] or (text.splitlines()[0][:60] if text else "Untitled"),
            "created": row[1], "modified": row[2],
            "folder": folder_names.get(row[3], ""),
            "deleted": (row[3] in trash_folders) or bool(row[4]),
            "erased": data is None,
            "snippet": row[5] or "",
            "locked": locked,
            "text": text,
            "attachments": attachments(db, obj_cols, note_pk),
        })
    identifiers = set()
    if "ZIDENTIFIER" in obj_cols:
        identifiers = {r[0] for r in db.execute("SELECT ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT WHERE ZIDENTIFIER IS NOT NULL")}
    db.close()
    return notes, identifiers


def attachments(db, cols, note_pk):
    """Every attachment of a note, scanned-document pages included (children via ZPARENTATTACHMENT)."""
    if "ZNOTE" not in cols or "ZTYPEUTI" not in cols:
        return []
    fields_sql = ", ".join(f"a.{c}" if c != "NULL" else "NULL" for c in (
        "Z_PK", "ZIDENTIFIER", "ZTYPEUTI", col(cols, "ZTITLE"), col(cols, "ZURLSTRING"),
        col(cols, "ZOCRSUMMARY"), col(cols, "ZHANDWRITINGSUMMARY"), col(cols, "ZMERGEABLEDATA1")))
    media = ", m.ZIDENTIFIER, m.ZFILENAME" if "ZMEDIA" in cols and "ZFILENAME" in cols else ", NULL, NULL"
    join = " LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON m.Z_PK = a.ZMEDIA" if "ZMEDIA" in cols else ""
    parent = col(cols, "ZPARENTATTACHMENT")
    found, queue, seen = [], [("a.ZNOTE = ?", note_pk)], set()
    while queue:
        where, value = queue.pop(0)
        for r in db.execute(f"SELECT {fields_sql}{media} FROM ZICCLOUDSYNCINGOBJECT a{join} WHERE {where} AND a.ZTYPEUTI IS NOT NULL", (value,)):
            if r[0] in seen:
                continue
            seen.add(r[0])
            found.append({"ident": r[1], "uti": r[2], "title": r[3], "url": r[4], "ocr": r[5],
                          "handwriting": r[6], "mergeable": r[7], "media_ident": r[8], "filename": r[9]})
            if parent != "NULL":
                queue.append((f"a.{parent} = ?", r[0]))
    return found


def when(value):
    if value is None:
        return ""
    try:
        return datetime.datetime.fromtimestamp(float(value) + APPLE_EPOCH).strftime("%Y-%m-%d %H:%M")
    except (ValueError, OverflowError, OSError):
        return ""


# --- attachment files -------------------------------------------------------------------------

def attachment_files(att, by_path, backup):
    """Backup files for one attachment, best first: full-size media, fallback image/PDF, else the largest
    preview. iOS empties a deleted note's media before removing it, so zero-byte files don't count."""
    def nonempty(pairs):
        return [(fid, rel) for fid, rel in pairs if os.path.getsize(backup_file(backup, fid)) > 0]
    full = nonempty((fid, rel) for rel, fid in by_path.items()
                    if att["media_ident"] and f"Media/{att['media_ident']}/" in rel)
    fallback = nonempty((fid, rel) for rel, fid in by_path.items()
                        if att["ident"] and re.search(rf"Fallback(Images|PDFs)/{re.escape(att['ident'])}\.", rel))
    if full or fallback:
        return full + fallback
    previews = nonempty((fid, rel) for rel, fid in by_path.items() if att["ident"] and f"Previews/{att['ident']}-" in rel)
    previews.sort(key=lambda p: -os.path.getsize(backup_file(backup, p[0])))
    return previews[:1]


# --- carving ---------------------------------------------------------------------------------

def carve(raw):
    """Every gzip stream in a file that decompresses to a note body."""
    found = []
    for m in re.finditer(b"\x1f\x8b\x08", raw):
        body = gunzip(raw[m.start():m.start() + 1_000_000])
        if len(body) < 8:
            continue
        text = clean(note_text(body))
        if len(text) >= 3:
            found.append((m.start(), text))
    return found


def safe_name(text, limit=50):
    name = re.sub(r"[^\w\- ]+", " ", text.splitlines()[0] if text else "untitled").strip()[:limit]
    return re.sub(r" {2,}", " ", name) or "untitled"


def write_note(folder, index, title, header, text):
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{index:03d} {safe_name(title)}.txt")
    with open(path, "w", encoding="utf-8") as f:
        f.write(header + "\n\n" + text + "\n")


def set_date(path, apple_time):
    if apple_time is not None:
        ts = float(apple_time) + APPLE_EPOCH
        os.utime(path, (ts, ts))


def export_deleted_note(folder, index, note, backup, by_path, copied):
    date = when(note["modified"] or note["created"])[:10]
    name = f"{index:03d} {safe_name(note['title'])}" + (f" ({date})" if date else "")
    path = os.path.join(folder, name)
    os.makedirs(path, exist_ok=True)

    lines = [f"Title: {note['title']}", f"Created: {when(note['created'])}", f"Modified: {when(note['modified'])}"]
    if note["locked"]:
        lines.append("This was a locked note. Its text is encrypted with your Notes password and can't be read here.")
    elif note["erased"]:
        lines.append("iPhone had already erased this note's text. Only what is listed below survived.")
    body = note["text"]
    if not body and note["snippet"]:
        body = f"(first line, as saved by Notes) {note['snippet']}"
    extra, files = [], 0
    for n, att in enumerate(note["attachments"], 1):
        if att["url"]:
            extra.append(f"Link: {att['url']}" + (f"  ({att['title']})" if att["title"] else ""))
        if att["ocr"]:
            extra.append(f"Text read from scan/photo {n}:\n{att['ocr'].strip()}")
        if att["handwriting"]:
            extra.append(f"Handwriting in drawing {n}:\n{att['handwriting'].strip()}")
        if att["uti"] == "com.apple.notes.table" and att["mergeable"]:
            cells = table_text(gunzip(att["mergeable"]))
            if cells:
                extra.append("Table:\n" + "\n".join(f"  {c}" for c in cells))
        for fid, rel in attachment_files(att, by_path, backup):
            ext = os.path.splitext(rel)[1].lower()
            if ext not in IMAGE_EXTS:
                continue
            src = backup_file(backup, fid)
            digest = hashlib.sha1(open(src, "rb").read()).hexdigest()
            if digest in copied:
                continue
            copied.add(digest)
            kind = "preview" if rel.startswith("Previews/") else "drawing" if "Fallback" in rel else "photo"
            base = os.path.splitext(att["filename"] or "")[0] or f"{kind} {n}"
            dest = os.path.join(path, f"{safe_name(base, 40)}{'' if kind == 'photo' else ' (' + kind + ')'}{ext}")
            k = 2
            while os.path.exists(dest):
                dest = os.path.join(path, f"{safe_name(base, 40)} ({k}){ext}")
                k += 1
            shutil.copyfile(src, dest)
            set_date(dest, note["modified"])
            files += 1
    with open(os.path.join(path, "note.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n\n" + (body or "(no text)") + "\n")
        if extra:
            f.write("\n\n" + "\n\n".join(extra) + "\n")
    set_date(os.path.join(path, "note.txt"), note["modified"])
    if not files and not body and not extra:
        shutil.rmtree(path)  # nothing at all survived
        return None
    return files


def main():
    backup, out = sys.argv[1], sys.argv[2]
    rows = manifest_rows(backup, "domain = ? AND relativePath IN ('NoteStore.sqlite', 'NoteStore.sqlite-wal', 'NoteStore.sqlite-shm')", (NOTES_DOMAIN,))
    if not rows:
        print("No NoteStore.sqlite in this backup (Notes may be off, or the backup is incomplete).")
        return
    work = tempfile.mkdtemp(prefix="notes-")
    for file_id, _, rel in rows:
        shutil.copyfile(backup_file(backup, file_id), os.path.join(work, rel))
    raw_main = open(os.path.join(work, "NoteStore.sqlite"), "rb").read()
    raw_wal = open(os.path.join(work, "NoteStore.sqlite-wal"), "rb").read() if os.path.exists(os.path.join(work, "NoteStore.sqlite-wal")) else b""

    notes, identifiers = live_notes(os.path.join(work, "NoteStore.sqlite"))  # applies the WAL to the private copy
    current = [n for n in notes if not n["deleted"]]
    deleted = sorted((n for n in notes if n["deleted"]), key=lambda n: n["modified"] or n["created"] or 0)
    live_texts = [n["text"] for n in notes if n["text"]]
    live_hashes = {hashlib.sha1(t.encode()).hexdigest() for t in live_texts}

    def matches_live(text):
        probe = text[:60]
        return any(probe and probe in t for t in live_texts)

    carved_deleted, carved_older = [], []
    seen = set()
    for source, raw in (("database free space", raw_main), ("write-ahead log", raw_wal)):
        for offset, text in carve(raw):
            h = hashlib.sha1(text.encode()).hexdigest()
            if h in live_hashes or h in seen:
                continue
            seen.add(h)
            (carved_older if matches_live(text) else carved_deleted).append((source, offset, text))

    by_path = {rel: fid for fid, _, rel in manifest_rows(backup, "domain = ?", (NOTES_DOMAIN,))}
    copied, exported, deleted_files, empty = set(), 0, 0, 0
    for n in deleted:
        result = export_deleted_note(os.path.join(out, "Deleted notes"), exported + 1, n, backup, by_path, copied)
        if result is None:
            empty += 1
        else:
            exported += 1
            deleted_files += result

    for i, (source, offset, text) in enumerate(carved_deleted, 1):
        write_note(os.path.join(out, "Deleted note text (recovered fragments)"), i, text,
                   f"Recovered from the Notes {source} at byte {offset}. Doesn't match any current note.\n"
                   "This may be a whole note or only part of one.", text)
    for i, (source, offset, text) in enumerate(carved_older, 1):
        write_note(os.path.join(out, "Older versions of current notes"), i, text,
                   f"Recovered from the Notes {source} at byte {offset}. An earlier version of a note you still have.", text)

    # Attachment files whose note is gone from the database entirely.
    orphan_media = 0
    for rel, fid in by_path.items():
        top = rel.split("/")[0]
        if top not in ("Media", "FallbackImages", "FallbackPDFs") or os.path.splitext(rel)[1].lower() not in IMAGE_EXTS:
            continue
        ident = rel.split("/")[1].split(".")[0]
        if ident in identifiers:
            continue
        src = backup_file(backup, fid)
        if os.path.getsize(src) == 0:
            continue
        digest = hashlib.sha1(open(src, "rb").read()).hexdigest()
        if digest in copied:
            continue
        copied.add(digest)
        dest = os.path.join(out, "Photos from erased notes", f"{ident[:8]}-{os.path.basename(rel)}")
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(src, dest)
        orphan_media += 1

    summary = (f"Notes in the backup: {len(notes)}\n"
               f"  current notes: {len(current)}\n"
               f"  deleted notes still in the database: {len(deleted)}\n"
               f"    exported (text and/or photos survived): {exported}, with {deleted_files} photos/scans/drawings\n"
               f"    nothing left to recover: {empty}\n"
               f"    locked with your Notes password: {sum(n['locked'] for n in deleted)}\n"
               f"Text recovered from deleted space: {len(carved_deleted)} fragments not matching any current note\n"
               f"Older versions of current notes: {len(carved_older)}\n"
               f"Photos whose note is gone entirely: {orphan_media}\n")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "summary.txt"), "w") as f:
        f.write(summary)
    print(summary, end="")
    shutil.rmtree(work)


if __name__ == "__main__":
    main()
