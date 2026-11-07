#!/usr/bin/env python3
"""Put the Datel OS logo into the boot splash of the K1's RTOS image.

The third core of the X2000 runs a closed FreeRTOS image (eMMC p3 for
slot 1, p4 for slot 2) whose only visible job is the logo on the panel
while Linux boots. The image carries one JPEG per panel orientation,
each followed by its size, and a symbol table that points at them; the
SPL keeps no checksum over the image. This replaces every JPEG in place
with a Datel splash of the same orientation, padded with zeros to the
original length, so the header, the code, the table and the sizes stay
byte for byte what they were.

  tools/rtos-splash.py DUMP.bin OUT.bin [--logo docs/logo.png]

DUMP.bin is the partition as read from the printer (dd if=/dev/mmcblk0p4
bs=1M count=4). Keep it: writing it back undoes everything. Needs Pillow.
"""
import argparse, hashlib, io, re, struct
from PIL import Image

p = argparse.ArgumentParser()
p.add_argument("dump"); p.add_argument("out")
p.add_argument("--logo", default="docs/logo.png")
p.add_argument("--size", type=int, default=240, help="logo height in pixels")
a = p.parse_args()

d = bytearray(open(a.dump, "rb").read())
assert d[8:12] == b"RTOS", "not an Ingenic RTOS image"
logo = Image.open(a.logo).convert("RGBA").resize((a.size, a.size), Image.LANCZOS)
BG = (11, 11, 12)

def splash(w, h, rot):
    im = Image.new("RGB", (w, h), BG)
    im.paste(logo, ((w - a.size) // 2, (h - a.size) // 2), logo)
    return im.rotate(rot, expand=True) if rot else im

# Every JPEG in the image, with its name from the symbol table that follows it:
# the name says the orientation (landscape/portrait, rot0/90/180) and the panel size.
names = {m.start(): m.group().decode() for m in re.finditer(rb"creality_[a-z]+_rot[0-9]+_[0-9]+x[0-9]+Data", d)}
i = 0; done = 0
while True:
    i = d.find(b"\xff\xd8\xff", i)
    if i < 0: break
    e = d.find(b"\xff\xd9", i) + 2
    size = e - i
    k = d.find(b"\xff\xc0", i, e)
    jh, jw = struct.unpack(">HH", d[k + 5:k + 9])
    # which table entry points here
    ref = d.find(struct.pack("<I", 0x86000000 + i))
    name_off = struct.unpack("<I", d[ref + 4:ref + 8])[0] - 0x86000000 if ref > 0 else -1
    name = names.get(name_off, "")
    m = re.match(r"creality_(landscape|portrait)_rot(\d+)_(\d+)x(\d+)", name)
    if m and (jw, jh) in ((480, 800), (800, 480)):
        kind, rot = m.group(1), int(m.group(2))
        if kind == "landscape" and (jw, jh) == (480, 800):
            # a landscape picture turned onto the portrait panel: rot0 reads
            # bottom to top (turned counter-clockwise), rot90/rot180 the other way
            im = splash(800, 480, 90 if rot == 0 else -90)
        elif kind == "portrait":
            im = splash(480, 800, 180 if rot == 180 else 0)
        else:
            im = splash(jw, jh, 0)
        for q in range(92, 30, -4):
            buf = io.BytesIO(); im.save(buf, "JPEG", quality=q, optimize=True, subsampling=2)
            if buf.tell() <= size: break
        new = buf.getvalue()
        assert len(new) <= size, name
        d[i:e] = new + b"\x00" * (size - len(new))
        print("%-40s %dx%d %6d -> %5d B (q=%d)" % (name, jw, jh, size, len(new), q))
        done += 1
    else:
        print("%-40s %dx%d %6d B kept" % (name or "(unnamed)", jw, jh, size))
    i = e
open(a.out, "wb").write(d)
print("%d splash images replaced; %s md5 %s" % (done, a.out, hashlib.md5(d).hexdigest()))
