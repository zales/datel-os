#!/bin/bash
# Input shaper calibration for Datel OS without running the fit on the printer.
#
# SHAPER_CALIBRATE forks a numpy process for the fit, which the K1's 256 MB
# of RAM cannot hold: the child is OOM-killed and Klipper waits for it for
# ever (restart klipper to recover). Record the raw data on the printer and
# fit it here instead:
#
#   on the printer (Mainsail console):  G28
#                                       TEST_RESONANCES AXIS=X OUTPUT=raw_data
#                                       TEST_RESONANCES AXIS=Y OUTPUT=raw_data
#   here:   PRINTER=root@<ip> tools/shaper-fit.sh
#
# Fetches /tmp/raw_data_*.csv from the printer, runs Kalico's own
# scripts/calibrate_shaper.py in a Python container (needs Docker) and
# leaves the plots as shaper-x.png / shaper-y.png in out/shaper/. Put the
# recommended shaper into the printer.cfg SAVE_CONFIG block
# (shaper_type_x/y, shaper_freq_x/y) and RESTART.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PRINTER="${PRINTER:-root@192.168.1.104}"
KEY="${KEY:-$HOME/.ssh/k1_printer_ecdsa}"
# the Kalico revision the image is built from (recipes-printer/kalico/kalico_git.bb)
REV="$(sed -n 's/^SRCREV = "\(.*\)"/\1/p' "$HERE/meta-creality-k1/recipes-printer/kalico/kalico_git.bb")"
OUT="$HERE/out/shaper"
mkdir -p "$OUT/kalico/scripts" "$OUT/kalico/klippy/extras"
for f in scripts/calibrate_shaper.py klippy/extras/shaper_calibrate.py klippy/extras/shaper_defs.py; do
    [ -s "$OUT/kalico/$f" ] || curl -sSf -o "$OUT/kalico/$f" "https://raw.githubusercontent.com/pellcorp/kalico/$REV/$f"
done
scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$PRINTER:/tmp/raw_data_*.csv" "$OUT/"
docker run --rm -v "$OUT":/w python:3.12-slim sh -c '
    pip install -q numpy matplotlib >/dev/null 2>&1
    cd /w/kalico
    for f in /w/raw_data_*.csv; do
        a=$(basename "$f" | sed "s/raw_data_\(.\)_.*/\1/")
        echo "=== axis $a: $(basename "$f")"
        python3 scripts/calibrate_shaper.py "$f" -o "/w/shaper-$a.png"
    done'
echo "plots: $OUT/shaper-*.png"
