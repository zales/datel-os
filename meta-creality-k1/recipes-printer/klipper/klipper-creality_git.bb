SUMMARY = "Klipper 3D printer host software, Creality K1 series fork"
DESCRIPTION = "Creality's published Klipper for the K1 series (GPL-3.0), including the \
prtouch strain-gauge probe in source form, plus the Linux host MCU (klipper_mcu) \
that the K1 config uses for its EEPROM ([mcu rpi], [bl24c16f])."
HOMEPAGE = "https://github.com/CrealityOfficial/K1_Series_Klipper"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=1ebbd3e34237af26da5dc08a4e440464"

SRC_URI = "git://github.com/CrealityOfficial/K1_Series_Klipper.git;protocol=https;branch=main \
           file://klipper.service \
           file://klipper-mcu.service \
           file://0001-linux-i2c-poll-on-nack.patch"
SRCREV = "e09f36e6ada60e5467b0bef731a96263b5d8095b"
PV = "k1-1.3.3.46+git${SRCPV}"
S = "${WORKDIR}/git"

inherit python3native systemd

SYSTEMD_SERVICE:${PN} = "klipper.service klipper-mcu.service"

KLIPPER_DIR = "${datadir}/klipper"

do_configure() {
    # Python 3.12 removed ConfigParser.readfp (mainline Klipper uses read_file).
    sed -i 's/fileconfig\.readfp(/fileconfig.read_file(/' ${S}/klippy/configfile.py
    # Creality bug: work_handler() only assigns the delay-photography/power-loss
    # variables when its settings file exists; a missing file raised UnboundLocalError
    # at the first print. Give them defaults first.
    sed -i 's|^\(\s*\)gcode_move = self.printer.lookup_object(.gcode_move., None)$|&\n\1delay_photography_switch, location, frame, interval, power_loss_switch = 1, 0, 15, 1, False|' ${S}/klippy/extras/virtual_sdcard.py
    grep -q 'delay_photography_switch, location, frame, interval, power_loss_switch = 1, 0, 15, 1, False' ${S}/klippy/extras/virtual_sdcard.py || bbfatal 'virtual_sdcard.py default patch did not apply'
    # The repository ships a prebuilt c_helper.so; build it from source below.
    rm -f ${S}/klippy/chelper/c_helper.so
    # Linux host MCU configuration
    echo "CONFIG_MACH_LINUX=y" > ${S}/.config
    oe_runmake -C ${S} PYTHON=python3 olddefconfig
}

do_compile() {
    cd ${S}/klippy/chelper
    srcs=$(python3 -c 'import re;print(" ".join(re.search(r"SOURCE_FILES = \[(.*?)\]",open("__init__.py").read(),re.S).group(1).replace("\x27","").replace(",","").split()))')
    ${CC} ${CFLAGS} ${LDFLAGS} -Wall -O2 -shared -fPIC -flto -fwhole-program -fno-use-linker-plugin \
        -o c_helper.so $srcs

    cd ${S}
    oe_runmake PYTHON=python3 CC="${CC}" CPP="${CPP}" LD="${LD}" AS="${AS}" \
        OBJCOPY="${OBJCOPY}" OBJDUMP="${OBJDUMP}" STRIP="${STRIP}" out/klipper.elf
}

do_install() {
    install -d ${D}${KLIPPER_DIR}
    cp -R --no-preserve=ownership ${S}/klippy ${D}${KLIPPER_DIR}/
    install -m 0644 ${S}/klippy/chelper/c_helper.so ${D}${KLIPPER_DIR}/klippy/chelper/c_helper.so
    find ${D}${KLIPPER_DIR} -name '*.o' -delete
    # The read-only root cannot hold __pycache__ at runtime; compile it now.
    python3 -m compileall -q -j 0 -s ${D} -p / ${D}${KLIPPER_DIR}/klippy || true

    install -d ${D}${bindir}
    install -m 0755 ${S}/out/klipper.elf ${D}${bindir}/klipper_mcu

    # Creality's code calls /usr/share/klippy-env/bin/python3 directly.
    install -d ${D}${datadir}/klippy-env/bin
    ln -sf ${bindir}/python3 ${D}${datadir}/klippy-env/bin/python3
    ln -sf ${bindir}/python3 ${D}${datadir}/klippy-env/bin/python
    # prtouch writes debug data below the install dir; send it to persistent storage.
    ln -sf /usr/data/k1os/klipper/pres_data ${D}${KLIPPER_DIR}/pres_data

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/klipper.service ${WORKDIR}/klipper-mcu.service ${D}${systemd_system_unitdir}/

    # Creality's MCU firmware for this fork; k1os-mcu-update puts it back on
    # the MCUs when another stack (Kalico) has flashed its own.
    install -d ${D}${KLIPPER_DIR}/fw/K1
    install -m 0644 ${S}/fw/K1/mcu0_120_G32-*.bin ${S}/fw/K1/noz0_120_G30-*.bin ${S}/fw/K1/bed0_110_G21-*.bin ${D}${KLIPPER_DIR}/fw/K1/
}

FILES:${PN} += "${KLIPPER_DIR} ${datadir}/klippy-env ${systemd_system_unitdir}"
# klipper_mcu is linked by Klipper's own Makefile, which does not take LDFLAGS.
INSANE_SKIP:${PN} += "already-stripped ldflags"

RDEPENDS:${PN} += " \
    k1os-base \
    k1os-mcu-update \
    python3-modules \
    python3-cffi \
    python3-greenlet \
    python3-jinja2 \
    python3-markupsafe \
    python3-pyserial \
    python3-numpy \
"
