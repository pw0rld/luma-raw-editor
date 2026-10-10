#!/usr/bin/env python3
"""Small uncompressed Bayer DNG for decoder smoke tests, not camera-quality validation."""
import math
import pathlib
import struct
import sys

width, height = 1024, 768
tags = {}
def tag(number, kind, values):
    if kind == 2:
        data = values.encode('ascii') + b'\0'; count = len(data)
    elif kind == 1:
        data = bytes(values); count = len(values)
    elif kind == 3:
        data = struct.pack('<' + 'H' * len(values), *values); count = len(values)
    elif kind == 4:
        data = struct.pack('<' + 'I' * len(values), *values); count = len(values)
    elif kind in (5, 10):
        data = b''.join(struct.pack('<ii' if kind == 10 else '<II', *v) for v in values); count = len(values)
    tags[number] = (kind, count, data)
for number, kind, values in [
    (254,4,[0]),(256,4,[width]),(257,4,[height]),(258,3,[16]),(259,3,[1]),(262,3,[32803]),
    (271,2,'Luma'),(272,2,'Synthetic Bayer'),(273,4,[0]),(274,3,[1]),(277,3,[1]),
    (278,4,[height]),(279,4,[width*height*2]),(284,3,[1]),
    (33421,3,[2,2]),(33422,1,[0,1,1,2]),
    (50706,1,[1,4,0,0]),(50707,1,[1,1,0,0]),(50708,2,'Luma Synthetic Bayer v1'),
    (50710,1,[0,1,2]),(50711,3,[1]),(50713,3,[1,1]),(50714,5,[(64,1)]),
    (50717,4,[4095]),(50718,5,[(1,1),(1,1)]),(50719,3,[0,0]),(50720,4,[width,height]),
    (50721,10,[(6722,10000),(-635,10000),(-963,10000),(-4287,10000),(12460,10000),(2028,10000),(-908,10000),(2162,10000),(5668,10000)]),
    (50728,5,[(1,2),(1,1),(2,3)]),(50730,10,[(0,1)]),(50778,3,[21])
]: tag(number,kind,values)
base = 8 + 2 + len(tags)*12 + 4
extra = bytearray(); entries = []
for number, (kind,count,data) in sorted(tags.items()):
    if len(data) <= 4: value = data.ljust(4,b'\0')
    else:
        if len(extra)%2: extra += b'\0'
        value = struct.pack('<I',base+len(extra)); extra += data
    entries.append([number,kind,count,value])
pixel_offset = base+len(extra)
for entry in entries:
    if entry[0] == 273: entry[3] = struct.pack('<I',pixel_offset)
header = b'II' + struct.pack('<HIH',42,8,len(tags))
ifd = b''.join(struct.pack('<HHI',n,k,c)+v for n,k,c,v in entries)+struct.pack('<I',0)
pixels = bytearray()
for y in range(height):
    for x in range(width):
        rgb = (0.08+0.7*x/(width-1), 0.08+0.7*y/(height-1), 0.15+0.45*(1-x/(width-1)))
        channel = (0,1,1,2)[(y%2)*2+x%2]
        pixels += struct.pack('<H', round(64+rgb[channel]*3900))
path = pathlib.Path(sys.argv[1]); path.parent.mkdir(parents=True,exist_ok=True)
path.write_bytes(header+ifd+extra+pixels)
print(path)
