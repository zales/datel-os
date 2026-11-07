#!/usr/bin/env python3
"""Write a G-code file that prints a thin solid sheet over (almost) the whole
K1 bed: a first-layer test for the whole mesh area.

  tools/sheet-gcode.py [--layers 2] [--ext 260] [--bed 105] [--margin 10] out.gcode

Layer 1 runs the lines along X, layer 2 along Y, each as one serpentine
without retractions. Uses the printer's START_PRINT / END_PRINT macros.
"""
import argparse, math

p = argparse.ArgumentParser()
p.add_argument("out")
p.add_argument("--layers", type=int, default=2)
p.add_argument("--ext", type=float, default=260)
p.add_argument("--bed", type=float, default=105)
p.add_argument("--margin", type=float, default=10)
p.add_argument("--size", type=float, default=220, help="bed size in mm")
p.add_argument("--width", type=float, default=0.5, help="extrusion width")
p.add_argument("--height", type=float, default=0.2, help="layer height")
p.add_argument("--speed1", type=float, default=60, help="first layer mm/s")
p.add_argument("--speed", type=float, default=100, help="other layers mm/s")
a = p.parse_args()

lo, hi = a.margin, a.size - a.margin
spacing = a.width * 0.9                      # slight overlap for a closed sheet
e_per_mm = a.width * a.height / (math.pi * 0.875 ** 2)   # 1.75 mm filament
n = int((hi - lo) / spacing) + 1
lines = []
w = lines.append
w("; K1 OS bed sheet: %d layer(s), %.0fx%.0f mm, width %.2f, height %.2f" % (a.layers, hi - lo, hi - lo, a.width, a.height))
w("START_PRINT EXTRUDER_TEMP=%.0f BED_TEMP=%.0f" % (a.ext, a.bed))
w("G90")
w("M82")
w("M106 S0")
e = 0.0
for layer in range(a.layers):
    z = a.height * (layer + 1)
    f = (a.speed1 if layer == 0 else a.speed) * 60
    w("; layer %d z=%.2f" % (layer + 1, z))
    w("G92 E0"); e = 0.0
    w("G1 Z%.3f F600" % (z + 1))
    along_x = (layer % 2 == 0)
    for i in range(n):
        c = lo + i * spacing                 # the line's fixed coordinate
        fwd = (i % 2 == 0)
        s, t = (lo, hi) if fwd else (hi, lo)
        if along_x:
            start, end = (s, c), (t, c)
        else:
            start, end = (c, s), (c, t)
        if i == 0:
            w("G1 X%.3f Y%.3f F12000" % start)
            w("G1 Z%.3f F600" % z)
        else:
            e += spacing * e_per_mm           # the short step to the next line
            w("G1 X%.3f Y%.3f E%.4f F%d" % (start[0], start[1], e, f))
        e += (hi - lo) * e_per_mm
        w("G1 X%.3f Y%.3f E%.4f F%d" % (end[0], end[1], e, f))
    w("G1 Z%.3f F600" % (z + 1))
w("END_PRINT")
open(a.out, "w").write("\n".join(lines) + "\n")
total_mm = a.layers * n * (hi - lo)
print("%s: %d lines/layer, %.0f m of extrusion, about %.0f min" % (a.out, n, total_mm / 1000,
      (n * (hi - lo) / a.speed1 + (a.layers - 1) * n * (hi - lo) / a.speed) / 60 * 1.15))
