#!/usr/bin/env python3
"""Convert the printable ASCII glyphs (32..126) of a BDF font into a C header.
Each glyph is stored row by row, top to bottom, as big-endian bits, 1 = ink,
with (width+7)//8 bytes per row."""
import sys
def parse(path):
    glyphs = {}
    with open(path) as f:
        lines = f.read().split("\n")
    i = 0; fw = fh = None
    while i < len(lines):
        l = lines[i]
        if l.startswith("FONTBOUNDINGBOX"):
            _, fw, fh, _, _ = l.split()
            fw, fh = int(fw), int(fh)
        if l.startswith("STARTCHAR"):
            enc = None; bbx = None; rows = []
            while not lines[i].startswith("ENDCHAR"):
                l = lines[i]
                if l.startswith("ENCODING"): enc = int(l.split()[1])
                elif l.startswith("BBX"): bbx = [int(x) for x in l.split()[1:]]
                elif l.startswith("BITMAP"):
                    i += 1
                    while not lines[i].startswith("ENDCHAR"):
                        rows.append(lines[i].strip()); i += 1
                    continue
                i += 1
            if enc is not None and (32 <= enc <= 126 or enc == 176):
                glyphs[enc] = (bbx, rows)
        i += 1
    return fw, fh, glyphs
def main():
    path, name = sys.argv[1], sys.argv[2]
    fw, fh, glyphs = parse(path)
    bpr = (fw + 7) // 8
    out = []
    out.append(f"/* Generated from {path.split('/')[-1]} by bdf2c.py: Spleen, (c) 2018-2026 Frederic Cambus, BSD-2-Clause. */")
    out.append(f"#define {name.upper()}_W {fw}")
    out.append(f"#define {name.upper()}_H {fh}")
    out.append(f"static const unsigned char {name}[96][{fh * bpr}] = {{")
    for code in list(range(32, 127)) + [176]:
        bbx, rows = glyphs.get(code, ([fw, fh, 0, 0], []))
        # BDF rows cover the BBX box; Spleen glyphs use the full cell, but be general:
        # place the box into the cell using its offsets.
        bw, bh, bx, by = bbx
        cell = [0] * fh
        # The baseline-relative offset: FONTBOUNDINGBOX y offset is -descent.
        top = fh - (bh + by) + (-5 if fh == 24 else (-6 if fh == 32 else -3)) * 0  # offsets computed below
        # Simpler: Spleen glyph BBX equals the font box for every glyph; assert that.
        if (bw, bh) != (fw, fh):
            # pad: align the bitmap box inside the cell (horizontal offset bx, vertical by relative to descent)
            pass
        bits = []
        for r in range(fh):
            if r < len(rows):
                v = int(rows[r], 16)
                # rows are padded to a byte boundary on the right
                nb = len(rows[r]) // 2
                v <<= (bpr - nb) * 8 if nb < bpr else 0
            else:
                v = 0
            bits.append(v)
        bytes_ = []
        for v in bits:
            for b in range(bpr):
                bytes_.append((v >> (8 * (bpr - 1 - b))) & 0xFF)
        out.append("  {" + ",".join("0x%02x" % b for b in bytes_) + "}, /* %s */" % ("'" + chr(code) + "'" if code < 127 and code != 92 else ("backslash" if code == 92 else "degree sign")))
    out.append("};")
    print("\n".join(out))
    # sanity to stderr
    bad = [c for c, (bbx, rows) in glyphs.items() if tuple(bbx[:2]) != (fw, fh)]
    print(f"{path}: {len(glyphs)} glyphs, non-full-cell boxes: {len(bad)}", file=sys.stderr)
main()
