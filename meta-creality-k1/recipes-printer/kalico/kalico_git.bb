SUMMARY = "Kalico (Klipper fork) host software, pellcorp's K1 branch"
DESCRIPTION = "Kalico with pellcorp's K1 series additions: the load cell probe for the \
bed strain gauges (hx711s), the Creality MCU bootloader entry and MIPS fixes. Pairs \
with the MCU firmware from k1-mcu-firmware built from the same release branch."
HOMEPAGE = "https://github.com/pellcorp/kalico"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=1ebbd3e34237af26da5dc08a4e440464"

SRC_URI = "git://github.com/pellcorp/kalico.git;protocol=https;branch=aug2026 \
           file://klipper.service \
           file://klipper-mcu.service \
           file://k1os_kalico.cfg \
           file://k1os-kalico-config \
           file://k1os-kalico-config.service"
SRCREV = "e8150318ec6174766c317b1a2c00ee4b0a651d11"
PV = "aug2026+git${SRCPV}"
S = "${WORKDIR}/git"

inherit python3native systemd

SYSTEMD_SERVICE:${PN} = "klipper.service klipper-mcu.service k1os-kalico-config.service"

KLIPPER_DIR = "${datadir}/klipper"

do_configure() {
    rm -f ${S}/klippy/chelper/c_helper.so
    # Linux host MCU configuration shipped by the fork (.config.host).
    cp ${S}/.config.host ${S}/.config
    oe_runmake -C ${S} PYTHON=python3 olddefconfig
}

do_compile() {
    cd ${S}/klippy/chelper
    srcs=$(python3 -c 'import re;print(" ".join(re.findall(r"[\x27\"]([A-Za-z0-9_]+\.c)[\x27\"]", re.search(r"SOURCE_FILES = \[(.*?)\]",open("__init__.py").read(),re.S).group(1))))')
    ${CC} ${CFLAGS} ${LDFLAGS} -Wall -O2 -shared -fPIC -flto -fwhole-program -fno-use-linker-plugin \
        -o c_helper.so $srcs

    cd ${S}
    oe_runmake PYTHON=python3 CC="${CC}" CPP="${CPP}" LD="${LD}" AS="${AS}" \
        OBJCOPY="${OBJCOPY}" OBJDUMP="${OBJDUMP}" STRIP="${STRIP}" out/klipper.elf
}

do_install() {
    install -d ${D}${KLIPPER_DIR}
    cp -R --no-preserve=ownership ${S}/klippy ${D}${KLIPPER_DIR}/
    cp -R --no-preserve=ownership ${S}/config ${D}${KLIPPER_DIR}/
    # Moonraker serves <klipper>/docs and warns when the directory is missing;
    # the text alone (the images are 20 MB)
    install -d ${D}${KLIPPER_DIR}/docs
    install -m 0644 ${S}/docs/*.md ${D}${KLIPPER_DIR}/docs/
    install -m 0644 ${S}/klippy/chelper/c_helper.so ${D}${KLIPPER_DIR}/klippy/chelper/c_helper.so
    find ${D}${KLIPPER_DIR} -name '*.o' -delete
    python3 -m compileall -q -j 0 -s ${D} -p / ${D}${KLIPPER_DIR}/klippy || true
    # Without a git checkout Klipper reads its version from .version
    echo "kalico-aug2026-g${@d.getVar('SRCREV')[:8]}" > ${D}${KLIPPER_DIR}/klippy/.version

    install -d ${D}${bindir}
    install -m 0755 ${S}/out/klipper.elf ${D}${bindir}/klipper_mcu

    install -d ${D}${systemd_system_unitdir} ${D}${libexecdir}/k1os ${D}${sysconfdir}/k1os
    install -m 0644 ${WORKDIR}/klipper.service ${WORKDIR}/klipper-mcu.service ${WORKDIR}/k1os-kalico-config.service ${D}${systemd_system_unitdir}/
    install -m 0755 ${WORKDIR}/k1os-kalico-config ${D}${libexecdir}/k1os/kalico-config
    install -m 0644 ${WORKDIR}/k1os_kalico.cfg ${D}${sysconfdir}/k1os/k1os_kalico.cfg
}

FILES:${PN} += "${KLIPPER_DIR} ${systemd_system_unitdir} ${libexecdir}/k1os ${sysconfdir}/k1os"
INSANE_SKIP:${PN} += "already-stripped ldflags"

RCONFLICTS:${PN} = "klipper-creality"
RDEPENDS:${PN} += " \
    k1os-base \
    python3-modules \
    python3-cffi \
    python3-greenlet \
    python3-jinja2 \
    python3-markupsafe \
    python3-pyserial \
    python3-numpy \
    k1-mcu-firmware \
"
