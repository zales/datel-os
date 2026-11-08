#!/bin/bash
# One Datel OS release: build the image variants, collect the files the release
# ships, check them and write the release notes. .github/workflows/release.yml
# runs the same steps on a tag; locally it is the manual fallback.
#
#   tools/release.sh build [variant...]   ./build.sh per variant (default: both), collect after each
#   tools/release.sh collect <variant>    copy xImage, rootfs and the OTA package out of the Docker
#                                         volume into release/ under their release names
#   tools/release.sh sums                 write release/SHA256SUMS
#   tools/release.sh check                names, sizes against the eMMC slots, SHA256SUMS, the OTA
#                                         contents (kernel and rootfs only), version against the tag
#   tools/release.sh notes                release notes (Markdown) on stdout
#   tools/release.sh version              the version the tag names, after checking DISTRO_VERSION
#
# TAG          release tag vX.Y.Z[-suffix] (default: the tag on HEAD); X.Y.Z must equal
#              DISTRO_VERSION in meta-creality-k1/conf/distro/k1os.conf
# RELEASE_DIR  where the files go (default: release/)
# Variants:    klipper-creality (kas-creality-k1.yml), kalico (kas-creality-k1-kalico.yml)
#
# A release never contains a bootloader or an RTOS image: the stock SPL and
# U-Boot stay in place and the slot keeps its RTOS. "check" fails on any such file.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="${RELEASE_DIR:-$HERE/release}"
VOLUME="${VOLUME:-k1yocto-work}"
DEPLOY=/work/k1-yocto/build/tmp/deploy/images/creality-k1
BOARD=CR4CU220812S11
REPO_URL=https://github.com/zales/k1-yocto
KERNEL_SLOT=$((8 * 1024 * 1024))      # mmcblk0p5 / p6
ROOTFS_SLOT=$((300 * 1024 * 1024))    # mmcblk0p7 / p8

die() { echo "release.sh: $*" >&2; exit 1; }
size() { wc -c < "$1" | tr -d ' '; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
sevenzip() {
    if command -v 7zz >/dev/null; then 7zz "$@"
    elif command -v 7z >/dev/null; then 7z "$@"
    else die "7zz or 7z is needed to look inside the OTA package (brew install sevenzip / apt install 7zip)"
    fi
}
awake() { if command -v caffeinate >/dev/null; then caffeinate -i "$@"; else "$@"; fi; }

kas_file() {
    case "$1" in
        klipper-creality) echo kas-creality-k1.yml ;;
        kalico) echo kas-creality-k1-kalico.yml ;;
        *) die "unknown variant '$1' (klipper-creality or kalico)" ;;
    esac
}
describe() {
    case "$1" in
        klipper-creality) echo "system with Creality's Klipper and the stock MCU firmware" ;;
        kalico) echo "system with Kalico and its own MCU firmware (reflashes all three MCUs on a cold start)" ;;
    esac
}

# The tag and everything derived from it.
TAG="${TAG:-$(git -C "$HERE" describe --tags --exact-match 2>/dev/null || true)}"
[ -n "$TAG" ] || die "HEAD has no tag; set TAG=vX.Y.Z"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "tag '$TAG' is not vX.Y.Z[-suffix]"
VER="${TAG#v}"; VER="${VER%%-*}"
OTA_VER="9.$VER"                           # CREALITY_OTA_VERSION = 9.${DISTRO_VERSION}
OTA_DIR="${BOARD}_ota_img_V${OTA_VER}"     # the directory inside the package = the file name
OTA_NAME="$OTA_DIR.img"
KERNEL_NAME="datel-os-$TAG-xImage"
rootfs_name() { echo "datel-os-$TAG-$1.squashfs"; }
ota_name() { echo "datel-os-$TAG-$1.ota.img"; }

version() {
    local dv
    dv=$(sed -n 's/^DISTRO_VERSION = "\(.*\)"/\1/p' "$HERE/meta-creality-k1/conf/distro/k1os.conf")
    [ "$dv" = "$VER" ] || die "tag $TAG but DISTRO_VERSION is '$dv' in meta-creality-k1/conf/distro/k1os.conf"
    echo "$VER"
}

build() {
    [ $# -gt 0 ] || set -- klipper-creality kalico
    local v
    for v in "$@"; do kas_file "$v" >/dev/null; done
    version >/dev/null
    for v in "$@"; do
        echo "== build $v ($(kas_file "$v"))"
        KAS_FILE="$(kas_file "$v")" awake "$HERE/build.sh"
        collect "$v"
    done
    sums
}

collect() {
    local v="${1:?variant}" staged
    kas_file "$v" >/dev/null
    mkdir -p "$RELEASE_DIR"
    staged="$RELEASE_DIR/$KERNEL_NAME.$v"
    # The deploy dir lives in the Docker volume: copy through a throw-away container.
    docker run --rm -u "$(id -u):$(id -g)" -v "$VOLUME:/work:ro" -v "$RELEASE_DIR:/out" \
        -e DEPLOY="$DEPLOY" -e OTA_NAME="$OTA_NAME" -e K="$KERNEL_NAME.$v" -e R="$(rootfs_name "$v")" -e O="$(ota_name "$v")" \
        busybox sh -ec '
            cd "$DEPLOY"
            have=$(readlink k1-image-creality-k1.rootfs.creality-ota)
            [ "$have" = "$OTA_NAME" ] || { echo "deploy dir holds $have, the tag wants $OTA_NAME: rebuild from the tagged tree" >&2; exit 1; }
            cp -L xImage "/out/$K"
            cp -L k1-image-creality-k1.rootfs.squashfs-xz "/out/$R"
            cp -L "$OTA_NAME" "/out/$O"'
    # One kernel for all variants; it must be the same file.
    if [ -e "$RELEASE_DIR/$KERNEL_NAME" ]; then
        cmp -s "$RELEASE_DIR/$KERNEL_NAME" "$staged" || die "the kernel of $v differs from the one collected before"
        unlink "$staged"
    else
        mv "$staged" "$RELEASE_DIR/$KERNEL_NAME"
    fi
    echo "== collected $v into $RELEASE_DIR"
    ls -l "$RELEASE_DIR/$KERNEL_NAME" "$RELEASE_DIR/$(rootfs_name "$v")" "$RELEASE_DIR/$(ota_name "$v")"
}

sums() {
    cd "$RELEASE_DIR"
    local f
    : > SHA256SUMS.new
    for f in $(find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -exec basename {} \; | sort); do sha256 "$f" >> SHA256SUMS.new; done
    mv SHA256SUMS.new SHA256SUMS
    cat SHA256SUMS
}

variants_present() {
    local f
    for f in "$RELEASE_DIR"/datel-os-"$TAG"-*.ota.img; do
        [ -e "$f" ] || continue
        f="${f##*/datel-os-"$TAG"-}"; echo "${f%.ota.img}"
    done
}

check_ota() {   # $1 package: only the tagged version, only kernel and rootfs chunks inside
    local f="$1" pw paths p base bad=0 types
    pw=$(openssl passwd -1 -salt cxswfile "${BOARD}C3_7e_bz")
    paths=$(sevenzip l -slt -ba -p"$pw" "$f" | sed -n 's/^Path = //p') || die "cannot list $f"
    [ -n "$paths" ] || die "$f: empty listing"
    while IFS= read -r p; do
        [ "$p" = "$OTA_DIR" ] && continue
        case "$p" in "$OTA_DIR"/*) ;; *) echo "  $p: outside $OTA_DIR" >&2; bad=1; continue ;; esac
        if [ "$p" = "$OTA_DIR/ota_config.in" ] || [ "$p" = "$OTA_DIR/ota_v$OTA_VER" ]; then continue; fi
        case "$p" in "$OTA_DIR/ota_v$OTA_VER"/*) ;; *) echo "  $p: not under ota_v$OTA_VER" >&2; bad=1; continue ;; esac
        base="${p##*/}"
        if ! [[ "$base" =~ ^(ota_v$OTA_VER\.ok|ota_update\.in|ota_md5_(xImage|rootfs\.squashfs)\.[0-9a-f]{32}|(xImage|rootfs\.squashfs)\.[0-9]{4}\.[0-9a-f]{32})$ ]]; then
            echo "  $p: not a kernel or rootfs chunk" >&2; bad=1
        fi
    done <<< "$paths"
    [ "$bad" = 0 ] || die "$f carries more than the kernel and the root filesystem"
    types=$(sevenzip e -so -p"$pw" "$f" "$OTA_DIR/ota_v$OTA_VER/ota_update.in" | sed -n 's/^img_type=//p' | sort | tr '\n' ' ')
    [ "$types" = "kernel rootfs " ] || die "$f: ota_update.in installs '$types', expected kernel and rootfs only"
    echo "  $(basename "$f"): $OTA_DIR, $(echo "$paths" | grep -c "/xImage\.[0-9]") kernel chunks, $(echo "$paths" | grep -c "/rootfs\.squashfs\.[0-9]") rootfs chunks, img_type: $types"
}

check() {
    version >/dev/null
    [ -d "$RELEASE_DIR" ] || die "no $RELEASE_DIR"
    cd "$RELEASE_DIR"
    local f lc v n found=0
    # Only the files a release ships, and nothing that smells like a bootloader.
    for f in *; do
        lc=$(echo "$f" | tr '[:upper:]' '[:lower:]')
        case "$lc" in *u-boot*|*uboot*|*spl*|*xboot*|*rtos*|*zero.bin*|*.dtb|*.bin|*.tgz|*.tar*)
            die "$f: bootloader, RTOS or stray build output, never part of a release" ;; esac
        case "$f" in
            SHA256SUMS|"$KERNEL_NAME") ;;
            datel-os-"$TAG"-*.squashfs|datel-os-"$TAG"-*.ota.img) ;;
            *) die "unexpected file $f in $RELEASE_DIR" ;;
        esac
    done
    [ -s SHA256SUMS ] || die "SHA256SUMS missing (tools/release.sh sums)"
    sha256 -c --quiet SHA256SUMS || die "SHA256SUMS does not match"
    [ -f "$KERNEL_NAME" ] || die "$KERNEL_NAME missing"
    n=$(size "$KERNEL_NAME"); [ "$n" -le "$KERNEL_SLOT" ] || die "$KERNEL_NAME is $n B, the kernel slot has $KERNEL_SLOT"
    echo "  $KERNEL_NAME: $n B"
    for v in $(variants_present); do
        kas_file "$v" >/dev/null
        f=$(rootfs_name "$v"); [ -f "$f" ] || die "$f missing"
        n=$(size "$f"); [ "$n" -le "$ROOTFS_SLOT" ] || die "$f is $n B, the rootfs slot has $ROOTFS_SLOT"
        echo "  $f: $n B"
        check_ota "$(ota_name "$v")"
        found=$((found + 1))
    done
    [ "$found" -gt 0 ] || die "no variant in $RELEASE_DIR"
    echo "check OK: $TAG (DISTRO_VERSION $VER, OTA $OTA_VER), $found variant(s): $(variants_present | tr '\n' ' ')"
}

notes() {
    local sha prev range v
    sha=$(git -C "$HERE" rev-parse --short "$TAG^{commit}" 2>/dev/null || git -C "$HERE" rev-parse --short HEAD)
    prev=$(git -C "$HERE" describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)
    echo "Datel OS images for the Creality K1 (board $BOARD, Ingenic X2000), built from commit $sha."
    echo
    echo "| Soubor | Obsah |"
    echo "|---|---|"
    echo "| \`$KERNEL_NAME\` | Linux 6.6-rt kernel, \`xImage\` for mmcblk0p5/p6 |"
    for v in $(variants_present); do
        echo "| \`$(rootfs_name "$v")\` | $(describe "$v"), squashfs for mmcblk0p7/p8 |"
    done
    for v in $(variants_present); do
        echo "| \`$(ota_name "$v")\` | the same as a package for the Creality updater (variant $v); rename to \`$OTA_NAME\` before use |"
    done
    echo "| \`SHA256SUMS\` | checksums of all files |"
    echo
    echo "Installation is described in [docs/RELEASE.md]($REPO_URL/blob/$TAG/docs/RELEASE.md). The package holds only the kernel and the system and is written into the inactive slot; the bootloader, the RTOS and partition \`mmcblk0p9\` are not touched. Datel OS boots in trial mode: until you run \`k1os-slot keep\`, a power cycle brings the previous system back."
    echo
    if [ -n "$prev" ]; then
        echo "## Changes since $prev"
        range="$prev..$TAG"
    else
        echo "## Changes (first release)"
        range="$TAG"
    fi
    echo
    git -C "$HERE" log --no-merges --format='- %s (%h)' "$range" 2>/dev/null || git -C "$HERE" log --no-merges --format='- %s (%h)'
    if [ -n "$prev" ]; then echo; echo "Full diff: $REPO_URL/compare/$prev...$TAG"; fi
}

case "${1:-}" in
    build) shift; build "$@" ;;
    collect) collect "${2:-}" ;;
    sums) sums ;;
    check) check ;;
    notes) notes ;;
    version) version ;;
    *) sed -n '2,20p' "$0" >&2; exit 1 ;;
esac
