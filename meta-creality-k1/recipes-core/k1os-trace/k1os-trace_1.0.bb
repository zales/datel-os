SUMMARY = "k1os-trace: a flight recorder for Klipper shutdowns"
DESCRIPTION = "Samples once a second who had the CPUs, how long Klipper and the other \
services waited for one, how late a 10 ms timer fires, how far ahead Klipper has planned \
and what the Wi-Fi carried. Keeps fifteen minutes in memory and writes them to \
/usr/data/k1os/trace/ with the end of klippy.log and of the journal when Klipper shuts \
down, or on SIGUSR1. Late wake-ups and long waits also go to the journal as they happen."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://k1os-trace.c file://k1os-trace.service"
S = "${WORKDIR}"

inherit systemd

do_compile() {
    ${CC} ${CFLAGS} -Wall -Wextra -std=gnu11 ${LDFLAGS} -o ${B}/k1os-trace ${WORKDIR}/k1os-trace.c
}

do_install() {
    install -d ${D}${bindir} ${D}${systemd_system_unitdir}
    install -m 0755 ${B}/k1os-trace ${D}${bindir}/k1os-trace
    install -m 0644 ${WORKDIR}/k1os-trace.service ${D}${systemd_system_unitdir}/
}

SYSTEMD_SERVICE:${PN} = "k1os-trace.service"
