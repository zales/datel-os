SUMMARY = "Timelapse encoding on the X2000 Helix video codec"
DESCRIPTION = "k1os-helix-enc decodes JPEG snapshots (the Helix JPEG decoder, or \
libjpeg-turbo with -S and as the fallback) and encodes them to H.264 on the Ingenic Helix block (V4L2 \
M2M node helix-venc), writing an Annex B stream; timelapse-render is the ffmpeg \
stand-in moonraker-timelapse calls, which runs the codec and lets h264-to-mp4 \
(recipe k1os-camera) wrap the stream into MP4. No H.264 is encoded on the CPU. Needs the kernel's \
CONFIG_INGENIC_HELIX with the fixed-QP rate control (INGENIC_HELIX_H264E_RC_NONE, \
patches 0001 and 0003 of linux-x2000) and the shared DMA pool of the K1 device tree."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://k1os-helix-enc.c \
           file://k1os-timelapse-render"
S = "${WORKDIR}"

# libjpeg-turbo decodes the camera JPEGs to NV12 when the Helix does not.
DEPENDS = "libjpeg-turbo"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -Wall -Wextra -o k1os-helix-enc ${WORKDIR}/k1os-helix-enc.c -ljpeg
}

do_install() {
    install -d ${D}${bindir} ${D}${libexecdir}/k1os
    install -m 0755 ${B}/k1os-helix-enc ${D}${bindir}/k1os-helix-enc
    install -m 0755 ${WORKDIR}/k1os-timelapse-render ${D}${libexecdir}/k1os/timelapse-render
}

FILES:${PN} += "${libexecdir}/k1os"
# h264-to-mp4
RDEPENDS:${PN} += "k1os-camera"
