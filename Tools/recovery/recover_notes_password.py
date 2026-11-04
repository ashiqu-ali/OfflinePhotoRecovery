#!/usr/bin/env python3
"""Recovers a FORGOTTEN Apple Notes password for the owner's own locked note in their own backup, by
trying likely passwords offline against the note's own key. It cannot break the AES encryption; it can
only test guesses, so it finds the password only if the real one (or a close variant) is among them.

    python3 -I recover_notes_password.py <backup folder> <guesses file> [--pins N] [--deep]

Oracle: PBKDF2-SHA256(guess, salt, 20000) -> 16-byte key; RFC 3394 unwrap of the note's wrapped key
either succeeds (right password) or is rejected. No network, nothing stored. Ctrl-C to stop.
"""
import ctypes
import hashlib
import itertools
import os
import sqlite3
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

RFC3394_IV = bytes.fromhex("A6A6A6A6A6A6A6A6")
cc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
NOTES_DOMAIN = "AppDomainGroup-group.com.apple.notes"


def unwraps(kek, wrapped):
    out, n = ctypes.create_string_buffer(len(wrapped)), ctypes.c_size_t(len(wrapped) - 8)
    return cc.CCSymmetricKeyUnwrap(1, RFC3394_IV, 8, kek, len(kek), wrapped, len(wrapped), out, ctypes.byref(n)) == 0


def load_targets(backup):
    """(salt, iters, wrapped_key) for every password-protected object; they all share one password."""
    path = None
    m = sqlite3.connect(f"file:{backup}/Manifest.db?mode=ro&immutable=1", uri=True)
    for fid, rel in m.execute("SELECT fileID, relativePath FROM Files WHERE flags=1 AND domain=? AND relativePath='NoteStore.sqlite'", (NOTES_DOMAIN,)):
        path = f"{backup}/{fid[:2]}/{fid}"
    db = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)
    rows = db.execute("SELECT ZCRYPTOSALT, ZCRYPTOITERATIONCOUNT, ZCRYPTOWRAPPEDKEY FROM ZICCLOUDSYNCINGOBJECT "
                      "WHERE ZCRYPTOWRAPPEDKEY IS NOT NULL AND ZCRYPTOSALT IS NOT NULL").fetchall()
    # One fast, well-formed target is enough to test a guess.
    return [r for r in rows if r[0] and r[1] and r[2]]


# --- candidate expansion ----------------------------------------------------------------------

SUFFIXES = ["", "1", "12", "123", "1234", "12345", "123456", "!", "@", "#", "01", "007", "007", "00",
            "!23", "321", "786", "143", "99", "69", "420", "111", "222", "000"]
YEARS = [str(y) for y in range(1975, 2027)]


def variants(word, deep):
    word = word.strip()
    if not word:
        return
    bases = {word, word.lower(), word.upper(), word.capitalize(), word.title()}
    if deep:
        leet = word.lower().translate(str.maketrans("aeiostb", "4310578"))
        bases |= {leet, leet.capitalize()}
    suffixes = SUFFIXES + YEARS if deep else SUFFIXES + YEARS[-30:]
    seen = set()
    for b in bases:
        if b and b not in seen:
            seen.add(b); yield b
        for s in suffixes:
            for cand in (b + s, s + b):
                if cand and cand not in seen:
                    seen.add(cand); yield cand


def candidates(guess_file, pins, deep):
    """Guesses first (most likely), then their mutations, then optional numeric PINs."""
    bases = []
    if os.path.exists(guess_file):
        with open(guess_file, encoding="utf-8", errors="replace") as f:
            bases = [ln.rstrip("\n") for ln in f if ln.strip() and not ln.lstrip().startswith("#")]
    emitted = set()
    for b in bases:                       # exact lines first
        if b not in emitted:
            emitted.add(b); yield b
    for b in bases:                       # then mutations
        for v in variants(b, deep):
            if v not in emitted:
                emitted.add(v); yield v
    for length in range(3, pins + 1):     # then numeric PINs of each length
        for digits in itertools.product("0123456789", repeat=length):
            p = "".join(digits)
            if p not in emitted:
                yield p


def main():
    backup, guess_file = sys.argv[1], sys.argv[2]
    pins = int(sys.argv[sys.argv.index("--pins") + 1]) if "--pins" in sys.argv else 0
    deep = "--deep" in sys.argv
    targets = load_targets(backup)
    if not targets:
        sys.exit("No locked note with a recoverable key in this backup.")
    salt, iters, wrapped = targets[0]

    found = threading.Event()
    result = {}
    tried = [0]
    lock = threading.Lock()

    def test(pw):
        if found.is_set():
            return
        kek = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8", "replace"), salt, iters, 16)
        if unwraps(kek, wrapped):
            result["pw"] = pw
            found.set()
        with lock:
            tried[0] += 1

    start = time.time()
    stop_reporter = threading.Event()

    def report():
        while not stop_reporter.wait(2):
            n = tried[0]; rate = n / max(time.time() - start, 0.001)
            print(f"\r  tried {n:,}   {rate:,.0f}/sec   latest result: {'FOUND' if found.is_set() else 'not yet'}   ", end="", flush=True)

    threading.Thread(target=report, daemon=True).start()
    print(f"Testing guesses against your locked note (PBKDF2 x{iters}). Ctrl-C to stop.\n")
    try:
        with ThreadPoolExecutor(max_workers=os.cpu_count()) as pool:
            for pw in candidates(guess_file, pins, deep):
                if found.is_set():
                    break
                pool.submit(test, pw)
    except KeyboardInterrupt:
        found.set()
        print("\nStopped.")
    stop_reporter.set()
    time.sleep(0.05)
    print()
    if "pw" in result:
        print("\n" + "=" * 60)
        print(f"  PASSWORD FOUND: {result['pw']}")
        print("=" * 60)
        print("\nNow unlock the note with it:")
        print(f'  python3 -I "{os.path.join(os.path.dirname(os.path.abspath(__file__)), "unlock_notes.py")}" \\')
        print(f'    "{backup}" \\')
        print('    "<your output folder>/Notes/Unlocked notes"')
        print("  (type the password above when it asks)")
    else:
        print(f"\nTried {tried[0]:,} guesses in {time.time() - start:.0f}s. The password was not among them.")
        print("Add more real guesses to the guesses file and run again, or add --deep / --pins 6.")


if __name__ == "__main__":
    main()
