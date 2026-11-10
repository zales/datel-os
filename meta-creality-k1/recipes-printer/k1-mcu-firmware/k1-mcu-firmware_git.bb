SUMMARY = "Klipper (Kalico) firmware for the three Creality K1 MCUs"
DESCRIPTION = "pellcorp's Kalico tree with Creality's GD32 port, from a fork that puts the \
scheduler back to upstream (a late timer shuts the MCU down instead of being moved), \
drops the port's debug counters and links with GCC 13. Built for the K1 main \
board (gd32f303xe, mcu0), nozzle board (gd32f303xb, noz0) and bed leveling board \
(gd32e230x8, bed0, with the load cell probe). The images carry Creality's bootloader \
header, so the stock serial bootloader accepts them."
HOMEPAGE = "https://github.com/zales/k1-kalico-firmware"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=1ebbd3e34237af26da5dc08a4e440464"

# pellcorp/k1-kalico-firmware, branch aug2026, plus five commits (see the fork's log).
SRC_URI = "git://github.com/zales/k1-kalico-firmware.git;protocol=https;branch=fix/gd32-port-cleanup"
SRCREV = "290bac3f056bc40543a92bb5963a49c9d7cb8731"
PV = "aug2026+git${SRCPV}"
S = "${WORKDIR}/git"

DEPENDS = "gcc-arm-none-eabi-native python3-native"
# Firmware images for the MCUs, not host binaries.
inherit allarch
INHIBIT_DEFAULT_DEPS = "1"

K1_MCU_TARGETS = "mcu noz bed"

# The link fix for Arm's GNU toolchain 13.2 (the unwinder's exception index
# symbols) used to be patched into the Makefile here; the fork carries it.
do_configure() {
    grep -q "defsym=__exidx_start" ${S}/src/gd32/Makefile || bbfatal "the gd32 Makefile lacks the GCC 13 link fix: wrong source tree?"
}

do_compile() {
    export PATH="${STAGING_BINDIR_NATIVE}:${PATH}"
    rm -rf ${B}/fw && mkdir -p ${B}/fw
    for t in ${K1_MCU_TARGETS}; do
        cp ${S}/.config.$t ${S}/.config
        oe_runmake -C ${S} clean
        oe_runmake -C ${S} olddefconfig
        oe_runmake -C ${S} CROSS_PREFIX=arm-none-eabi-
        bin=$(ls ${S}/out/*000.bin)
        cp $bin ${B}/fw/
        echo "$t -> $(basename $bin)"
    done
}

do_install() {
    install -d ${D}${datadir}/klipper/fw/K1
    install -m 0644 ${B}/fw/*.bin ${D}${datadir}/klipper/fw/K1/
}

FILES:${PN} = "${datadir}/klipper/fw"
RDEPENDS:${PN} = "k1os-mcu-update"
