SUMMARY = "Moonraker: API web server for Klipper"
DESCRIPTION = "Upstream master, October 2026. Older Moonraker (v0.8.0, January 2024) \
was the version the K1 community ran with Creality's Klipper; the current one \
stores its database in SQLite and migrates an existing LMDB database itself."
HOMEPAGE = "https://github.com/Arksine/moonraker"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://LICENSE;md5=db95b6e40dc7d26d8308b6b7375637b6"

SRC_URI = "git://github.com/Arksine/moonraker.git;protocol=https;branch=master \
           file://moonraker.service \
           file://moonraker.conf \
           file://0001-file_manager-build-file-listings-off-the-event-loop.patch \
          "
SRCREV = "b559b9a81161f958a43c2f527b6ad96f73310d5d"
PV = "0.11.0+git${SRCPV}"
S = "${WORKDIR}/git"

inherit python3native systemd allarch

DEPENDS += "git-native"

SYSTEMD_SERVICE:${PN} = "moonraker.service"

do_compile[noexec] = "1"

do_install() {
    install -d ${D}${datadir}/moonraker
    # scripts/ holds host install helpers that a read-only image does not use.
    cp -R --no-preserve=ownership ${S}/moonraker ${D}${datadir}/moonraker/
    # Without a git checkout Moonraker reads its version from .version
    git -C ${S} describe --tags --always --long > ${D}${datadir}/moonraker/moonraker/.version || \
        echo "v0.11.0-git${SRCPV}" > ${D}${datadir}/moonraker/moonraker/.version
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
    python3-dbus-fast \
    python3-importlib-metadata \
    python3-sqlite3 \
    python3-periphery \
    iproute2 \
    sudo \
"
# sudo: the systemd_cli provider of Moonraker's machine component runs every
# service action as "sudo systemctl ..." even as root; without the binary
# Mainsail's Services menu (k1os-twitch, ustreamer, ...) fails with HTTP 500.
