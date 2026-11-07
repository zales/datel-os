SUMMARY = "Datel OS base system files"
DESCRIPTION = "Mounts the shared /usr/data partition and prepares the Datel OS namespace on it. \
Datel OS never mounts mmcblk0p9, the stock firmware's overlay partition."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://after-volatile-lib.conf file://usr-data.mount file://k1os-datadir.service file://k1os-datadir-setup \
           file://k1os-wifi.service file://80-wlan.network file://guppyscreen-restart \
           file://serial-autologin.conf file://k1os-wifi-mac \
           file://k1os-slot file://k1os-trial-boot.service file://k1os-slot-confirm.service \
           file://k1os-bootlog.service file://k1os-bootlog.timer \
           file://k1os-seed-webcam file://k1os-seed-webcam.service"
S = "${WORKDIR}"

inherit systemd allarch

SYSTEMD_SERVICE:${PN} = "usr-data.mount k1os-datadir.service k1os-wifi.service \
                         k1os-trial-boot.service k1os-slot-confirm.service k1os-bootlog.timer k1os-seed-webcam.service"

do_install() {
    install -d ${D}${systemd_system_unitdir} ${D}/usr/data ${D}${libexecdir}/k1os ${D}${sysconfdir}/k1os
    install -m 0644 ${WORKDIR}/usr-data.mount ${WORKDIR}/k1os-datadir.service ${D}${systemd_system_unitdir}/
    install -m 0755 ${WORKDIR}/k1os-datadir-setup ${D}${libexecdir}/k1os/datadir-setup
    install -m 0755 ${WORKDIR}/guppyscreen-restart ${D}${libexecdir}/k1os/guppyscreen-restart
    install -m 0755 ${WORKDIR}/k1os-wifi-mac ${D}${libexecdir}/k1os/wifi-mac
    install -m 0755 ${WORKDIR}/k1os-slot ${D}${libexecdir}/k1os/slot
    install -d ${D}${sbindir}
    ln -sf ${libexecdir}/k1os/slot ${D}${sbindir}/k1os-slot
    install -m 0644 ${WORKDIR}/k1os-trial-boot.service ${WORKDIR}/k1os-slot-confirm.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/k1os-bootlog.service ${WORKDIR}/k1os-bootlog.timer ${D}${systemd_system_unitdir}/
    install -m 0755 ${WORKDIR}/k1os-seed-webcam ${D}${libexecdir}/k1os/seed-webcam
    install -m 0644 ${WORKDIR}/k1os-seed-webcam.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/k1os-wifi.service ${D}${systemd_system_unitdir}/
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${WORKDIR}/80-wlan.network ${D}${sysconfdir}/systemd/network/
    install -d ${D}${sysconfdir}/systemd/system/serial-getty@ttyS2.service.d
    install -m 0644 ${WORKDIR}/serial-autologin.conf ${D}${sysconfdir}/systemd/system/serial-getty@ttyS2.service.d/autologin.conf
    for u in systemd-backlight@.service systemd-rfkill.service; do
        install -d ${D}${sysconfdir}/systemd/system/$u.d
        install -m 0644 ${WORKDIR}/after-volatile-lib.conf ${D}${sysconfdir}/systemd/system/$u.d/10-after-volatile-lib.conf
    done
}

FILES:${PN} += "${systemd_system_unitdir} /usr/data"
RDEPENDS:${PN} += "util-linux-mountpoint wpa-supplicant openssh-keygen iproute2"
