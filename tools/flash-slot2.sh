#!/bin/bash
# Write Datel OS into the slot that is not running, over SSH. Slot 2 is
# kernel2 = mmcblk0p6 + rootfs2 = mmcblk0p8 (written while slot 1 runs); slot 1
# is kernel = mmcblk0p5 + rootfs = mmcblk0p7 (written while slot 2 runs).
# Nothing else on the eMMC is touched.
#
#   tools/flash-slot2.sh            check only, writes nothing
#   tools/flash-slot2.sh --write    write and verify the slot, marker untouched
#   tools/flash-slot2.sh --switch   point the marker at that slot (next boot)
#
# SLOT=2 (default) or SLOT=1 picks the target. Images come from out/;
# OUT=out/kalico flashes another variant. KERNEL= and ROOTFS= name the two
# files directly, e.g. the ones from a GitHub Release.
#
# Datel OS boots as a trial: its first step points the marker back at slot 1,
# so a power cycle returns to stock until you run "k1os-slot keep" on it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PRINTER="${PRINTER:-root@192.168.1.104}"
KEY="${KEY:-$HOME/.ssh/k1_printer_ecdsa}"
PUBKEY="${PUBKEY:-$KEY.pub}"
# Stock and Datel OS have different host keys and may swap IP leases, so the
# host-key cache is not used; the printer is authenticated by our own key.
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$PRINTER")
OUT="${OUT:-$HERE/out}"
KERNEL="${KERNEL:-$OUT/xImage-k1os}"
ROOTFS="${ROOTFS:-$OUT/k1-image-rootfs.squashfs}"
MODE="${1:-check}"
SLOT="${SLOT:-2}"
case "$SLOT" in
2) KDEV=/dev/mmcblk0p6; RDEV=/dev/mmcblk0p8; FROM=/dev/mmcblk0p7; MARK_FROM=ota:kernel;  MARK_TO=ota:kernel2 ;;
1) KDEV=/dev/mmcblk0p5; RDEV=/dev/mmcblk0p7; FROM=/dev/mmcblk0p8; MARK_FROM=ota:kernel2; MARK_TO=ota:kernel ;;
*) echo "STOP: SLOT must be 1 or 2" >&2; exit 1 ;;
esac
OTHER=$(( 3 - SLOT ))

die() { echo "STOP: $*" >&2; exit 1; }
md5of() { md5 -q "$1"; }

# Pad to whole 4 KiB blocks so the read-back can use dd with block counts.
pad4k() {
    local f="$1" out="$2" size pad
    cp "$f" "$out"
    size=$(stat -f %z "$out")
    pad=$(( (4096 - size % 4096) % 4096 ))
    [ "$pad" -gt 0 ] && dd if=/dev/zero bs=1 count="$pad" 2>/dev/null >> "$out"
    return 0
}

[ -f "$KERNEL" ] || die "missing $KERNEL"
[ -f "$ROOTFS" ] || die "missing $ROOTFS"
[ -f "$PUBKEY" ] || die "missing $PUBKEY (Datel OS allows SSH login with a key only)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pad4k "$KERNEL" "$TMP/kernel"; pad4k "$ROOTFS" "$TMP/rootfs"
KS=$(stat -f %z "$TMP/kernel"); RS=$(stat -f %z "$TMP/rootfs")
KM=$(md5of "$TMP/kernel"); RM=$(md5of "$TMP/rootfs")

echo "== printer state"
STATE=$("${SSH[@]}" '
  echo "cmdline=$(cat /proc/cmdline)"
  echo "marker=$(dd if=/dev/mmcblk0p1 bs=512 count=1 2>/dev/null | tr -d "\000" | head -n 1)"
  echo "kdev=$(( $(cat /sys/class/block/'"${KDEV#/dev/}"'/size) * 512 ))"
  echo "rdev=$(( $(cat /sys/class/block/'"${RDEV#/dev/}"'/size) * 512 ))"
  q="http://127.0.0.1:7125/printer/objects/query?print_stats=state"
  echo "print=$( (curl -s "$q" 2>/dev/null || wget -T 3 -qO- "$q" 2>/dev/null) | sed -n "s/.*\"state\": *\"\([a-z]*\)\".*/\1/p")"
')
echo "$STATE"
get() { echo "$STATE" | sed -n "s/^$1=//p"; }

case " $(get cmdline) " in *" root=$FROM "*) ;; *) die "not running from slot $OTHER ($FROM); refusing to touch slot $SLOT" ;; esac
[ "$(get marker)" = "$MARK_FROM" ] || [ "$MODE" = "--switch" ] || die "marker is '$(get marker)', expected $MARK_FROM"
case "$(get print)" in printing|paused) die "a print is $(get print); wait until it finishes" ;; esac
[ "$KS" -le "$(get kdev)" ] || die "kernel $KS B does not fit $KDEV"
[ "$RS" -le "$(get rdev)" ] || die "rootfs $RS B does not fit $RDEV"
echo "== images (slot $SLOT)"
echo "kernel  $KS B  md5 $KM  -> $KDEV"
echo "rootfs  $RS B  md5 $RM  -> $RDEV"

verify() {  # $1 dev, $2 size, $3 md5
    local got
    got=$("${SSH[@]}" "dd if=$1 bs=4096 count=$(( $2 / 4096 )) 2>/dev/null | md5sum | cut -d' ' -f1")
    [ "$got" = "$3" ] || die "$1 read-back md5 $got != $3"
    echo "$1 verified ($got)"
}

case "$MODE" in
check)
    echo "== check only, nothing written. Next: $0 --write" ;;
--write)
    echo "== writing kernel ($KDEV)"
    "${SSH[@]}" "dd of=$KDEV bs=4096 2>/dev/null; sync" < "$TMP/kernel"
    verify "$KDEV" "$KS" "$KM"
    echo "== writing rootfs ($RDEV), about a minute"
    "${SSH[@]}" "dd of=$RDEV bs=4096 2>/dev/null; sync" < "$TMP/rootfs"
    verify "$RDEV" "$RS" "$RM"
    echo "== SSH key for Datel OS (/usr/data/k1os/ssh/authorized_keys)"
    "${SSH[@]}" 'mkdir -p /usr/data/k1os/ssh && chmod 700 /usr/data/k1os/ssh && k=$(cat) &&
      { grep -qxF "$k" /usr/data/k1os/ssh/authorized_keys 2>/dev/null || echo "$k" >> /usr/data/k1os/ssh/authorized_keys; } &&
      chmod 600 /usr/data/k1os/ssh/authorized_keys && sync && wc -l < /usr/data/k1os/ssh/authorized_keys' < "$PUBKEY"
    echo "== slot $SLOT written and verified, marker still $MARK_FROM. Next: SLOT=$SLOT $0 --switch" ;;
--switch)
    verify "$KDEV" "$KS" "$KM"
    verify "$RDEV" "$RS" "$RM"
    "${SSH[@]}" "
      b=/tmp/k1os-marker
      { printf '$MARK_TO\n\n'; dd if=/dev/zero bs=$(( 512 - ${#MARK_TO} - 2 )) count=1 2>/dev/null; } > \$b
      dd if=\$b of=/dev/mmcblk0p1 bs=512 count=1 2>/dev/null; sync; rm -f \$b
      dd if=/dev/mmcblk0p1 bs=512 count=1 2>/dev/null | tr -d '\000' | head -n 1"
    echo "== marker points at slot $SLOT. Reboot the printer to try it." ;;
*)
    die "unknown option $MODE" ;;
esac
