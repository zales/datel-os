SUMMARY = "moonraker-timelapse: layer change timelapse for Moonraker and Mainsail"
DESCRIPTION = "The timelapse component of mainsail-crew (macro version 1.15): the \
TIMELAPSE_TAKE_FRAME macro fetches a camera snapshot at every layer change, or a \
hyperlapse timer does, and the frames are rendered into an MP4 at the end of the \
print. On Datel OS the render step calls timelapse-render from k1os-helix, which \
uses the X2000 hardware codec instead of ffmpeg's software x264."
HOMEPAGE = "https://github.com/mainsail-crew/moonraker-timelapse"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://LICENSE;md5=1ebbd3e34237af26da5dc08a4e440464"

SRC_URI = "git://github.com/mainsail-crew/moonraker-timelapse.git;protocol=https;branch=main \
           file://timelapse.conf"
SRCREV = "c7fff11e542b95e0e15b8bb1443cea8159ac0274"
PV = "1.15+git${SRCPV}"
S = "${WORKDIR}/git"

inherit allarch

do_compile[noexec] = "1"

do_install() {
    # Moonraker loads any module in its components directory as [name] section.
    install -d ${D}${datadir}/moonraker/moonraker/components
    install -m 0644 ${S}/component/timelapse.py ${D}${datadir}/moonraker/moonraker/components/
    python3 -m compileall -q -s ${D} -p / ${D}${datadir}/moonraker/moonraker/components/timelapse.py || true
    # Included from printer.cfg by an absolute path (k1os_kalico.cfg does it).
    install -d ${D}${datadir}/k1os
    install -m 0644 ${S}/klipper_macro/timelapse.cfg ${D}${datadir}/k1os/timelapse.cfg
    # Appended once to the user's moonraker.conf by k1os-datadir-setup.
    install -d ${D}${sysconfdir}/k1os/moonraker.d
    install -m 0644 ${WORKDIR}/timelapse.conf ${D}${sysconfdir}/k1os/moonraker.d/timelapse.conf
}

FILES:${PN} += "${datadir}/moonraker ${datadir}/k1os"
RDEPENDS:${PN} += "moonraker k1os-helix"
