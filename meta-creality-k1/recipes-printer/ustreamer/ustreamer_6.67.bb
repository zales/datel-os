SUMMARY = "uStreamer: lightweight MJPEG streamer for V4L2 cameras"
HOMEPAGE = "https://github.com/pikvm/ustreamer"
LICENSE = "GPL-3.0-or-later"
LIC_FILES_CHKSUM = "file://LICENSE;md5=d32239bcb673463ab874e80d47fae504"

SRC_URI = "git://github.com/pikvm/ustreamer.git;protocol=https;branch=master \
           file://k1os-camera-device \
           file://k1os-camera-stream \
           file://ustreamer.service \
           file://0001-capture-missing-JPEG-quality-control-is-not-an-error.patch"
SRCREV = "0e64f1fedab4030c7bf58a287c462e21919c1d48"
S = "${WORKDIR}/git"

DEPENDS = "libevent libjpeg-turbo libbsd"

inherit systemd pkgconfig

# The K1 camera encodes MJPEG itself, so no CPU encoder, Python, Janus or GPIO
# support is built in.
EXTRA_OEMAKE = "PREFIX=${prefix} CC='${CC}' CFLAGS='${CFLAGS}' LDFLAGS='${LDFLAGS}' \
                WITH_PYTHON=0 WITH_JANUS=0 WITH_V4P=0 WITH_GPIO=0 WITH_SYSTEMD=0"

do_compile() {
    oe_runmake apps
}

do_install() {
    install -d ${D}${bindir} ${D}${libexecdir}/k1os ${D}${systemd_system_unitdir}
    install -m 0755 ${S}/src/ustreamer.bin ${D}${bindir}/ustreamer
    install -m 0755 ${S}/src/ustreamer-dump.bin ${D}${bindir}/ustreamer-dump
    install -m 0755 ${WORKDIR}/k1os-camera-device ${D}${libexecdir}/k1os/camera-device
    install -m 0755 ${WORKDIR}/k1os-camera-stream ${D}${libexecdir}/k1os/camera-stream
    install -m 0644 ${WORKDIR}/ustreamer.service ${D}${systemd_system_unitdir}/
}

SYSTEMD_SERVICE:${PN} = "ustreamer.service"
FILES:${PN} += "${libexecdir}/k1os"
