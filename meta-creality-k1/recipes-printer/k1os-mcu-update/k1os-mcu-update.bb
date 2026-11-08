SUMMARY = "Flash the Creality K1 MCUs over their serial bootloader at boot"
DESCRIPTION = "k1os-mcu-flash talks to the Creality bootloader of the three K1 MCUs; \
k1os-mcu-update compares each MCU's version with the images in /usr/share/klipper/fw/K1 \
before Klipper starts and flashes the ones that differ. The images come from \
k1-mcu-firmware, so Kalico always boots with the MCU firmware it was built with."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://k1os-mcu-flash file://k1os-mcu-update file://k1os-mcu-update.service"
S = "${WORKDIR}"

inherit allarch systemd

do_install() {
    install -d ${D}${libexecdir}/k1os ${D}${systemd_system_unitdir}
    install -m 0755 ${WORKDIR}/k1os-mcu-flash ${D}${libexecdir}/k1os/mcu-flash
    install -m 0755 ${WORKDIR}/k1os-mcu-update ${D}${libexecdir}/k1os/mcu-update
    install -m 0644 ${WORKDIR}/k1os-mcu-update.service ${D}${systemd_system_unitdir}/
}

SYSTEMD_SERVICE:${PN} = "k1os-mcu-update.service"
FILES:${PN} = "${libexecdir}/k1os ${systemd_system_unitdir}"
RDEPENDS:${PN} = "python3-core python3-pyserial"
