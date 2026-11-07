#!/bin/bash
# Write K1 OS into slot 2 (kernel2 = mmcblk0p6, rootfs2 = mmcblk0p8) over SSH,
# while stock keeps running from slot 1. Nothing else on the eMMC is touched.
#
#   tools/flash-slot2.sh            check only, writes nothing
#   tools/flash-slot2.sh --write    write and verify slot 2, marker untouched
#   tools/flash-slot2.sh --switch   point the marker at slot 2 (next boot)
#
# K1 OS boots as a trial: its first step points the marker back at slot 1,
# so a power cycle returns to stock until you run "k1os-slot keep" on it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PRINTER="${PRINTER:-root@192.168.1.104}"
KEY="${KEY:-$HOME/.ssh/k1_printer_ecdsa}"
PUBKEY="${PUBKEY:-$KEY.pub}"
# Stock and K1 OS have different host keys and may swap IP leases, so the
# host-key cache is not used; the printer is authenticated by our own key.
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$PRINTER")
KERNEL="$HERE/out/xImage-k1os"
ROOTFS="$HERE/out/k1-image-rootfs.squashfs"
MODE="${1:-check}"

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
[ -f "$PUBKEY" ] || die "missing $PUBKEY (K1 OS allows SSH login with a key only)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pad4k "$KERNEL" "$TMP/kernel"; pad4k "$ROOTFS" "$TMP/rootfs"
KS=$(stat -f %z "$TMP/kernel"); RS=$(stat -f %z "$TMP/rootfs")
KM=$(md5of "$TMP/kernel"); RM=$(md5of "$TMP/rootfs")

echo "== printer state"
STATE=$("${SSH[@]}" '
  echo "cmdline=$(cat /proc/cmdline)"
  echo "marker=$(dd if=/dev/mmcblk0p1 bs=512 count=1 2>/dev/null | tr -d "\000" | head -n 1)"
  echo "p6=$(( $(cat /sys/class/block/mmcblk0p6/size) * 512 ))"
  echo "p8=$(( $(cat /sys/class/block/mmcblk0p8/size) * 512 ))"
  echo "print=$(curl "http://127.0.0.1:7125/printer/objects/query?print_stats=state" 2>/dev/null | sed -n "s/.*\"state\": *\"\([a-z]*\)\".*/\1/p")"
')
echo "$STATE"
get() { echo "$STATE" | sed -n "s/^$1=//p"; }

case " $(get cmdline) " in *" root=/dev/mmcblk0p7 "*) ;; *) die "not running from slot 1 (p7); refusing to touch slot 2" ;; esac
[ "$(get marker)" = "ota:kernel" ] || [ "$MODE" = "--switch" ] || die "marker is '$(get marker)', expected ota:kernel"
case "$(get print)" in printing|paused) die "a print is $(get print); wait until it finishes" ;; esac
[ "$KS" -le "$(get p6)" ] || die "kernel $KS B does not fit p6"
[ "$RS" -le "$(get p8)" ] || die "rootfs $RS B does not fit p8"
echo "== images"
echo "kernel  $KS B  md5 $KM  -> /dev/mmcblk0p6"
echo "rootfs  $RS B  md5 $RM  -> /dev/mmcblk0p8"

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
    echo "== writing kernel2 (p6)"
    "${SSH[@]}" 'dd of=/dev/mmcblk0p6 bs=4096 2>/dev/null; sync' < "$TMP/kernel"
    verify /dev/mmcblk0p6 "$KS" "$KM"
    echo "== writing rootfs2 (p8), about a minute"
    "${SSH[@]}" 'dd of=/dev/mmcblk0p8 bs=4096 2>/dev/null; sync' < "$TMP/rootfs"
    verify /dev/mmcblk0p8 "$RS" "$RM"
    echo "== SSH key for K1 OS (/usr/data/k1os/ssh/authorized_keys)"
    "${SSH[@]}" 'mkdir -p /usr/data/k1os/ssh && chmod 700 /usr/data/k1os/ssh && k=$(cat) &&
      { grep -qxF "$k" /usr/data/k1os/ssh/authorized_keys 2>/dev/null || echo "$k" >> /usr/data/k1os/ssh/authorized_keys; } &&
      chmod 600 /usr/data/k1os/ssh/authorized_keys && sync && wc -l < /usr/data/k1os/ssh/authorized_keys' < "$PUBKEY"
    echo "== slot 2 written and verified, marker still ota:kernel. Next: $0 --switch" ;;
--switch)
    verify /dev/mmcblk0p6 "$KS" "$KM"
    verify /dev/mmcblk0p8 "$RS" "$RM"
    "${SSH[@]}" '
      b=/tmp/k1os-marker
      { printf "ota:kernel2\n\n"; dd if=/dev/zero bs=499 count=1 2>/dev/null; } > $b
      dd if=$b of=/dev/mmcblk0p1 bs=512 count=1 2>/dev/null; sync; rm -f $b
      dd if=/dev/mmcblk0p1 bs=512 count=1 2>/dev/null | tr -d "\000" | head -n 1'
    echo "== marker points at slot 2. Power-cycle the printer to try K1 OS." ;;
*)
    die "unknown option $MODE" ;;
esac
