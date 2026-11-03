#!/usr/bin/env python3
"""Builds a fake "Photos folders copy" (what the app's fast USB copy produces) for testing.

It contains a Photos.sqlite listing some photos, thumbnails for photos that are still in the
library, in Recently Deleted, and gone, plus an edited version of a gone photo.

    python3 make_test_photo_copy.py --out /tmp/photocopy --image some.jpg
"""
import argparse
import datetime
import os
import plistlib
import shutil
import sqlite3


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--image", required=True, help="any JPEG used as the content of every test picture")
    args = parser.parse_args()

    root = os.path.join(os.path.abspath(args.out), "00008150-000A1B2C3D4E5F60-photos")
    if os.path.exists(root):
        shutil.rmtree(root)
    image = open(args.image, "rb").read()

    def put(path, data=image):
        full = os.path.join(root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(data)

    put("DCIM/100APPLE/IMG_0001.JPG")
    put("PhotoData/Thumbnails/V2/DCIM/100APPLE/IMG_0001.JPG/5005.JPG")      # still in library
    put("PhotoData/Thumbnails/V2/DCIM/100APPLE/IMG_0002.HEIC/5005.JPG")     # in Recently Deleted
    put("PhotoData/Thumbnails/V2/DCIM/101APPLE/IMG_0777.JPG/5005.JPG")      # gone from library
    put("PhotoData/Mutations/DCIM/101APPLE/IMG_0778/Adjustments/FullSizeRender.jpg")  # edit of a gone photo
    put("PhotoData/Thumbnails/3307.ithmb", os.urandom(8192))                # cache file: kept, not an image
    put("PhotoStreamsData/123/100CLOUD/IMG_0900.JPG")                       # shared album
    # iCloud Photos cache: full-size files named after their resource fingerprint.
    put("PhotoData/CPL/storage/filecache/AaA/cplAaAkeepFingerprint0001.jpeg")   # photo still in library
    put("PhotoData/CPL/storage/filecache/AaB/cplAaBkeepFingerprint0002.jpeg")   # photo still in library
    put("PhotoData/CPL/storage/filecache/AaZ/cplAaZgoneFingerprint0003.jpeg")   # original recorded as deleted
    put("PhotoData/CPL/storage/filecache/AaQ/cplAaQnoRecordFingerprint04.jpeg")  # no record either way
    # A photo filed under another DCIM folder than its thumbnail must still count as in the library.
    put("PhotoData/Thumbnails/V2/DCIM/120APPLE/IMG_0003.HEIC/5005.JPG")

    cpl = sqlite3.connect(os.path.join(root, "PhotoData", "CPL", "storage", "store.cloudphotodb"))
    cpl.execute("CREATE TABLE outgoingResources (scopeIndex INTEGER, itemIdentifier TEXT, resourceType INTEGER, fingerPrint TEXT)")
    cpl.execute("CREATE TABLE pushRepository (class TEXT, scopeIndex INTEGER, identifier TEXT, changeType INTEGER, trashed INTEGER)")
    cpl.execute("CREATE TABLE idMapping (stableScopeIndex INTEGER, cloudIdentifier TEXT, localIdentifier TEXT, deleteTimestamp REAL)")
    cpl.execute("INSERT INTO pushRepository VALUES ('CPLMasterChange', 0, 'AaZgoneFingerprint0003', 1024, 1)")
    cpl.commit()
    cpl.close()

    db = sqlite3.connect(os.path.join(root, "PhotoData", "Photos.sqlite"))
    db.execute("CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZDIRECTORY VARCHAR, ZFILENAME VARCHAR, ZTRASHEDSTATE INTEGER)")
    db.executemany("INSERT INTO ZASSET (ZDIRECTORY, ZFILENAME, ZTRASHEDSTATE) VALUES (?, ?, ?)", [
        ("DCIM/100APPLE", "IMG_0001.JPG", 0),
        ("DCIM/100APPLE", "IMG_0002.HEIC", 1),
        ("DCIM/100APPLE", "IMG_0003.HEIC", 0),
    ])
    db.execute("CREATE TABLE ZINTERNALRESOURCE (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZFINGERPRINT VARCHAR)")
    db.executemany("INSERT INTO ZINTERNALRESOURCE (ZASSET, ZFINGERPRINT) VALUES (?, ?)", [
        (1, "AaAkeepFingerprint0001"),
        (3, "AaBkeepFingerprint0002"),
    ])
    db.commit()
    db.close()

    with open(os.path.join(root, "OfflinePhotoFinder-copy.plist"), "wb") as f:
        plistlib.dump({"DeviceName": "Test iPhone", "ProductType": "iPhone10,3", "ProductVersion": "16.7.11",
                       "UDID": "00008150-000A1B2C3D4E5F60", "Date": datetime.datetime(2026, 11, 3, 12, 0)}, f)
    print(f"Wrote test photo-folder copy to {root}")


if __name__ == "__main__":
    main()
