#!/bin/bash
# Runs every automated check: the build, the crypto and file-format checks, and end-to-end scans
# of generated test data (no iPhone needed). CI runs this; run it yourself before a pull request.
# Needs macOS: Swift, sips and openssl.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SELFTEST="$ROOT/MacApp/.build/debug/photofinder-selftest"
LABELS=(python3 -I "$ROOT/Tools/check_labels.py")

echo "==> Build"
swift build --package-path "$ROOT/MacApp"

echo "==> Crypto and file-format checks"
"$SELFTEST" vectors

echo "==> Encrypted backup: unlock, find, export, label"
python3 -I "$ROOT/Tools/make_test_backup.py" --out "$WORK/enc" --password test123 >/dev/null
PF_PASSWORD=test123 "$SELFTEST" scan "$WORK/enc" --export "$WORK/out-enc" > "$WORK/enc.txt"
python3 -I "$ROOT/Tools/verify_export.py" "$WORK/enc/expected.json" "$WORK/out-enc"
"${LABELS[@]}" "$WORK/enc.txt" \
    "IMG_0001.HEIC=inLibrary" \
    "100APPLE/IMG_0003.JPG/5005.JPG=recentlyDeleted" \
    "IMG_7777.HEIC/5005.JPG=notInLibrary" \
    "1a2b3c4d.jpg=none"

echo "==> Wrong password is rejected"
if PF_PASSWORD=wrong "$SELFTEST" scan "$WORK/enc" > "$WORK/wrong.txt" 2>&1; then
    echo "FAIL: a wrong password was accepted"; exit 1
fi
grep -q "doesn't unlock this backup" "$WORK/wrong.txt" && echo "PASS wrong password rejected"

echo "==> Unencrypted backup"
python3 -I "$ROOT/Tools/make_test_backup.py" --out "$WORK/plain" --unencrypted >/dev/null
"$SELFTEST" scan "$WORK/plain" --export "$WORK/out-plain" > /dev/null
python3 -I "$ROOT/Tools/verify_export.py" "$WORK/plain/expected.json" "$WORK/out-plain"

echo "==> An unfinished backup is refused with a clear message"
STATUS="$(find "$WORK/plain" -name Status.plist | head -1)"
plutil -replace SnapshotState -string uploading "$STATUS"
if "$SELFTEST" scan "$WORK/plain" > "$WORK/unfinished.txt" 2>&1; then
    echo "FAIL: an unfinished backup was searched"; exit 1
fi
grep -q "hasn't finished yet" "$WORK/unfinished.txt" && echo "PASS unfinished backup refused"

echo "==> Photos-folder copy: labels against the library and iCloud records"
IMAGE="$(find "$WORK/out-plain" -name '1a2b3c4d.jpg' | head -1)"
python3 -I "$ROOT/Tools/make_test_photo_copy.py" --out "$WORK/copy" --image "$IMAGE" >/dev/null
"$SELFTEST" scan "$WORK/copy" > "$WORK/copy.txt"
"${LABELS[@]}" "$WORK/copy.txt" \
    "Media/DCIM/100APPLE/IMG_0001.JPG=inLibrary" \
    "100APPLE/IMG_0001.JPG/5005.JPG=inLibrary" \
    "IMG_0002.HEIC/5005.JPG=recentlyDeleted" \
    "IMG_0777.JPG/5005.JPG=notInLibrary" \
    "120APPLE/IMG_0003.HEIC/5005.JPG=inLibrary" \
    "IMG_0778/Adjustments=notInLibrary" \
    "cplAaAkeepFingerprint0001=inLibrary" \
    "cplAaZgoneFingerprint0003=notInLibrary" \
    "cplAaQnoRecordFingerprint04=none"

echo
echo "All checks passed."
