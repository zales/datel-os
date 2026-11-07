SUMMARY = "Klipper (Kalico) firmware for the three Creality K1 MCUs"
DESCRIPTION = "pellcorp's Kalico tree with Creality's GD32 port, built for the K1 main \
board (gd32f303xe, mcu0), nozzle board (gd32f303xb, noz0) and bed leveling board \
(gd32e230x8, bed0, with the load cell probe). The images carry Creality's bootloader \
header, so the stock serial bootloader accepts them."
HOMEPAGE = "https://github.com/pellcorp/k1-kalico-firmware"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=1ebbd3e34237af26da5dc08a4e440464"

SRC_URI = "git://github.com/pellcorp/k1-kalico-firmware.git;protocol=https;branch=aug2026"
SRCREV = "674a0f98f7d3148a0211d424c726e2c7b90a6024"
PV = "aug2026+git${SRCPV}"
S = "${WORKDIR}/git"

DEPENDS = "gcc-arm-none-eabi-native python3-native"
# Firmware images for the MCUs, not host binaries.
inherit allarch
INHIBIT_DEFAULT_DEPS = "1"

K1_MCU_TARGETS = "mcu noz bed"

do_configure() {
    # Arm's GNU toolchain 13.2 pulls libgcc's unwinder in through newlib-nano,
    # which then wants the exception index symbols. Nothing here unwinds, so
    # give the linker empty values instead of an .ARM.exidx section.
    sed -i 's|^CFLAGS_klipper.elf += --specs=nano.specs --specs=nosys.specs$|& -Wl,--defsym=__exidx_start=0 -Wl,--defsym=__exidx_end=0|' ${S}/src/gd32/Makefile
    grep -q "defsym=__exidx_start" ${S}/src/gd32/Makefile || bbfatal "gd32 Makefile link flag line not found"
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
RCONFLICTS:${PN} = "klipper-creality"
