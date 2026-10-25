#!/usr/bin/env python3
"""Package the generated PNG sizes when the host's iconutil is unavailable."""
import pathlib
import struct
import sys

iconset, output = map(pathlib.Path, sys.argv[1:])
sizes = [
    (b"icp4", "icon_16x16.png", 16), (b"ic11", "icon_16x16@2x.png", 32),
    (b"icp5", "icon_32x32.png", 32), (b"ic12", "icon_32x32@2x.png", 64),
    (b"ic07", "icon_128x128.png", 128), (b"ic13", "icon_128x128@2x.png", 256),
    (b"ic08", "icon_256x256.png", 256), (b"ic14", "icon_256x256@2x.png", 512),
    (b"ic09", "icon_512x512.png", 512), (b"ic10", "icon_512x512@2x.png", 1024),
]
chunks = []
for kind, filename, size in sizes:
    png = (iconset / filename).read_bytes()
    if png[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", png[16:24]) != (size, size):
        raise SystemExit(f"Invalid icon image: {filename}")
    chunks.append(kind + struct.pack(">I", len(png) + 8) + png)
payload = b"".join(chunks)
output.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
