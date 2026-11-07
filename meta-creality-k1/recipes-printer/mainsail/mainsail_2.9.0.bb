SUMMARY = "Mainsail web interface for Klipper"
DESCRIPTION = "Release build of Mainsail v2.9.0 (the version the K1 community install uses), \
served by nginx with the Moonraker API proxied on the same port."
HOMEPAGE = "https://github.com/mainsail-crew/mainsail"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-3.0-only;md5=c79ff39f19dfec6d293b95dea7b07891"

SRC_URI = "https://github.com/mainsail-crew/mainsail/releases/download/v${PV}/mainsail.zip;subdir=mainsail-dist \
           file://mainsail.nginx \
          "
SRC_URI[sha256sum] = "f4463bdc591ee1ea59c010e3e8f23742294e8351b13807b68f7de318cea7efdb"

S = "${WORKDIR}/mainsail-dist"

inherit allarch

do_install() {
    install -d ${D}${datadir}/mainsail
    cp -R --no-preserve=ownership ${S}/. ${D}${datadir}/mainsail/
    install -d ${D}${sysconfdir}/nginx/sites-enabled
    install -m 0644 ${WORKDIR}/mainsail.nginx ${D}${sysconfdir}/nginx/sites-enabled/mainsail
}

FILES:${PN} += "${datadir}/mainsail"
RDEPENDS:${PN} += "nginx moonraker"
