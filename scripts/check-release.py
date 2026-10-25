#!/usr/bin/env python3
import pathlib
import plistlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
version = plistlib.loads((root / "Info.plist").read_bytes())["CFBundleShortVersionString"]
expected = f"v{version}"
if len(sys.argv) != 2 or sys.argv[1] != expected:
    raise SystemExit(f"Release tag must match Info.plist: {expected}")
if (root / "RELEASE_NOTES.md").read_text().splitlines()[0] != f"# Luma RAW {expected}":
    raise SystemExit("RELEASE_NOTES.md version does not match the application")
print(f"PASS: release tag, Info.plist and release notes agree: {expected}")
