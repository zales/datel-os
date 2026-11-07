SUMMARY = "Moonraker: API web server for Klipper"
DESCRIPTION = "Pinned to the version the K1 community install runs with Creality's Klipper \
(v0.8.0-247-g3008a13, January 2024)."
HOMEPAGE = "https://github.com/Arksine/moonraker"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://LICENSE;md5=db95b6e40dc7d26d8308b6b7375637b6"

SRC_URI = "git://github.com/Arksine/moonraker.git;protocol=https;branch=master \
           file://moonraker.service \
           file://moonraker.conf \
          "
SRCREV = "3008a13efb6045a007456cb4f34a64afa6140617"
PV = "0.8.0+git${SRCPV}"
S = "${WORKDIR}/git"

inherit python3native systemd allarch

SYSTEMD_SERVICE:${PN} = "moonraker.service"

do_compile[noexec] = "1"

do_install() {
    install -d ${D}${datadir}/moonraker
    # scripts/ holds host install helpers that a read-only image does not use.
    cp -R --no-preserve=ownership ${S}/moonraker ${D}${datadir}/moonraker/
    # Without a git checkout Moonraker reads its version from .version
    echo "v0.8.0-247-g3008a13" > ${D}${datadir}/moonraker/moonraker/.version
    python3 -m compileall -q -j 0 -s ${D} -p / ${D}${datadir}/moonraker/moonraker || true

    install -d ${D}${systemd_system_unitdir} ${D}${sysconfdir}/k1os
    install -m 0644 ${WORKDIR}/moonraker.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/moonraker.conf ${D}${sysconfdir}/k1os/moonraker.conf
}

FILES:${PN} += "${datadir}/moonraker ${systemd_system_unitdir}"

RDEPENDS:${PN} += " \
    k1os-base \
    python3-modules \
    python3-tornado \
    python3-pyserial \
    python3-pyserial-asyncio \
    python3-pillow \
    python3-lmdb \
    python3-streaming-form-data \
    python3-distro \
    python3-inotify-simple \
    python3-libnacl \
    python3-paho-mqtt \
    python3-zeroconf \
    python3-preprocess-cancellation \
    python3-jinja2 \
    python3-dbus-next \
    python3-periphery \
    iproute2 \
"
