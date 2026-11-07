# Image type "creality-ota": a package the stock Creality updater (and Datel OS)
# installs into the inactive A/B slot of the K1.
#
# Format (reverse-engineered from firmware 1.3.3.46, see scripts/ota_pack.py):
# a 7z archive (LZMA2, AES, encrypted headers) named <board>_ota_img_V<ver>.img
# holding the kernel (xImage) and the root filesystem in 1 MiB MD5-chained
# chunks. The password is md5-crypt("<board>C3_7e_bz", salt "cxswfile").
# The RTOS image is left out on purpose: the slot keeps whatever RTOS it has.

CREALITY_BOARD ??= "CR4CU220812S11"
CREALITY_OTA_VERSION ??= "9.${@d.getVar('DISTRO_VERSION')}"
CREALITY_OTA_ROOTFS_TYPE ??= "squashfs-xz"

IMAGE_TYPEDEP:creality-ota = "${CREALITY_OTA_ROOTFS_TYPE}"
do_image_creality_ota[depends] += " \
    p7zip-native:do_populate_sysroot \
    openssl-native:do_populate_sysroot \
    python3-native:do_populate_sysroot \
    virtual/kernel:do_deploy \
"

IMAGE_CMD:creality-ota () {
    ver="${CREALITY_OTA_VERSION}"
    name="${CREALITY_BOARD}_ota_img_V${ver}"
    work="${WORKDIR}/creality-ota"
    rm -rf "$work" && mkdir -p "$work/images" "$work/pkg"

    cp "${DEPLOY_DIR_IMAGE}/xImage" "$work/images/xImage"
    cp "${IMGDEPLOYDIR}/${IMAGE_NAME}.${CREALITY_OTA_ROOTFS_TYPE}" "$work/images/rootfs.squashfs"

    python3 "${CREALITY_K1_LAYERDIR}/scripts/ota_pack.py" pack \
        "$work/images" "$work/pkg/$name" "$ver"
    python3 "${CREALITY_K1_LAYERDIR}/scripts/ota_pack.py" verify "$work/pkg/$name"

    pw="$(openssl passwd -1 -salt cxswfile "${CREALITY_BOARD}C3_7e_bz")"
    rm -f "${IMGDEPLOYDIR}/$name.img"
    (cd "$work/pkg" && 7z a -t7z -bd -m0=lzma2 -md=16m -ms=on -mhe=on -p"$pw" \
        "${IMGDEPLOYDIR}/$name.img" "$name" >/dev/null)
    ln -sf "$name.img" "${IMGDEPLOYDIR}/${IMAGE_LINK_NAME}.creality-ota"
}
