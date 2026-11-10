SUMMARY = "go2rtc: camera streaming server (WebRTC, MSE, MP4), prebuilt release binary"
DESCRIPTION = "go2rtc serves the camera's H.264 (k1os-stream on the Helix codec) to \
Mainsail's WebRTC player and to the Twitch stream, from one encoder that runs only \
while someone watches. The upstream release binary for linux/mipsle is static Go, \
so it needs no Go toolchain in the build."
HOMEPAGE = "https://github.com/AlexxIT/go2rtc"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "https://github.com/AlexxIT/go2rtc/releases/download/v${PV}/go2rtc_linux_mipsel;downloadfilename=go2rtc_${PV}_linux_mipsel;name=bin \
           file://go2rtc.yaml \
           file://go2rtc.service"
SRC_URI[bin.sha256sum] = "2a72e0acf2d5cb02b65ab99723e72faa8d786180f916048da7a78c831dbc7222"
S = "${WORKDIR}"

inherit systemd

do_install() {
    install -D -m 0755 ${WORKDIR}/go2rtc_${PV}_linux_mipsel ${D}${bindir}/go2rtc
    install -D -m 0644 ${WORKDIR}/go2rtc.yaml ${D}${sysconfdir}/go2rtc.yaml
    install -D -m 0644 ${WORKDIR}/go2rtc.service ${D}${systemd_system_unitdir}/go2rtc.service
}

SYSTEMD_SERVICE:${PN} = "go2rtc.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# A static Go binary as released upstream: nothing to strip or split.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INHIBIT_SYSROOT_STRIP = "1"
INSANE_SKIP:${PN} += "already-stripped ldflags arch"

# The stream "k1" runs /usr/libexec/k1os/h264-source from k1os-stream.
RDEPENDS:${PN} += "k1os-stream"
