SUMMARY = "Datel OS branding: login banner, prompt, logo and the Mainsail theme"
DESCRIPTION = "What makes the system say Datel OS: the motd scripts and the prompt \
at an SSH login, the logo, and the Mainsail theme files that k1os-datadir seeds \
into printer_data/config/.theme."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://motd-10-datel file://motd-20-datel file://datel-prompt.sh file://datel-login.sh \
           file://theme/sidebar-logo.svg file://theme/favicon-32x32.png file://theme/favicon-16x16.png"
S = "${WORKDIR}"

inherit allarch

do_install() {
    install -D -m 0755 ${WORKDIR}/motd-10-datel ${D}${nonarch_libdir}/datel/motd/10-datel
    install -D -m 0755 ${WORKDIR}/motd-20-datel ${D}${nonarch_libdir}/datel/motd/20-datel
    install -D -m 0644 ${WORKDIR}/datel-prompt.sh ${D}${nonarch_libdir}/datel/prompt.sh
    install -D -m 0644 ${WORKDIR}/datel-login.sh ${D}${sysconfdir}/profile.d/datel.sh
    install -d ${D}${datadir}/datel/theme
    install -m 0644 ${WORKDIR}/theme/sidebar-logo.svg ${WORKDIR}/theme/favicon-32x32.png ${WORKDIR}/theme/favicon-16x16.png ${D}${datadir}/datel/theme/
}

FILES:${PN} = "${nonarch_libdir}/datel ${sysconfdir}/profile.d ${datadir}/datel"
RDEPENDS:${PN} = "k1os-base wpa-supplicant iproute2"
