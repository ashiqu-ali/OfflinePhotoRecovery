#!/usr/bin/env python3
"""Checks the Photos-library labels in `photofinder-selftest scan` output.

    python3 -I check_labels.py <scan output> "<part of the path>=<label>" ...

<label> is inLibrary, recentlyDeleted, notInLibrary, or none (no label). Each path part must
match exactly one found item.
"""
import sys


def label_of(line):
    for field in (part.strip() for part in line.split("|")):
        if field.startswith("library: "):
            return field[len("library: "):]
    return "none"


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        items = [line for line in f if line.startswith("  [")]
    failures = 0
    for spec in sys.argv[2:]:
        part, wanted = spec.rsplit("=", 1)
        matches = [line for line in items if part in line]
        if len(matches) != 1:
            print(f"FAIL {part}: expected 1 matching item, found {len(matches)}")
            failures += 1
            continue
        got = label_of(matches[0])
        if got == wanted:
            print(f"PASS {part}: {got}")
        else:
            print(f"FAIL {part}: {got} (expected {wanted})")
            failures += 1
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
