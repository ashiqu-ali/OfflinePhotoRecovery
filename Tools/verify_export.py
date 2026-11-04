#!/usr/bin/env python3
"""Checks that an export holds exactly the expected media files, byte for byte.

    python3 -I verify_export.py <expected.json written by make_test_backup.py> <export folder>
"""
import hashlib
import json
import os
import sys


def main():
    expected_file, export_root = sys.argv[1], sys.argv[2]
    with open(expected_file) as f:
        expected = {entry["sha256"] for entry in json.load(f)}

    exported = set()
    for root, _, files in os.walk(export_root):
        for name in files:
            if name == "index.csv":
                continue
            with open(os.path.join(root, name), "rb") as f:
                exported.add(hashlib.sha256(f.read()).hexdigest())

    missing, extra = expected - exported, exported - expected
    if missing or extra:
        print(f"FAIL export: {len(missing)} expected files missing, {len(extra)} unexpected files")
        sys.exit(1)
    print(f"PASS export: all {len(expected)} distinct files exported byte for byte")


if __name__ == "__main__":
    main()
