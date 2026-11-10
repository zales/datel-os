SUMMARY = "k1os-stream: camera stream with a status overlay through the X2000 Helix codec, the Twitch service and its Mainsail controls"
DESCRIPTION = "k1os-stream takes the camera's MJPEG frames (from uStreamer's memory sink, so \
Mainsail keeps its camera), decodes them on the Helix, draws the print status into the \
picture and encodes H.264 on the Helix with a userspace rate controller on the QP \
controls. k1os-twitch.service sends that through ffmpeg to Twitch over RTMP. The \
Moonraker component k1os_stream starts and stops it from Mainsail (TWITCH dialog, \
macros, /server/k1os/stream) and keeps the Twitch stream title at the print state."
LICENSE = "MIT & BSD-2-Clause"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302 \
                    file://LICENSE.spleen;md5=6b0faaab001f2e05d12e136feb82cf71"

SRC_URI = "file://Makefile file://k1os-stream.c file://helix.c file://helix.h \
           file://overlay.c file://overlay.h file://moonraker.c file://moonraker.h \
           file://graph.c file://graph.h file://sysstat.c file://sysstat.h \
           file://font12x24.h file://font16x32.h file://jpeg_dht.h file://bdf2c.py file://LICENSE.spleen \
           file://k1os-twitch file://k1os-twitch.service file://k1os-twitch-autostart.service \
           file://k1os-twitch-asvc file://k1os-h264-source file://moonraker-k1os-twitch.conf file://twitch.env.example \
           file://k1os_stream.py file://k1os_stream.cfg file://k1os-stream.conf"
S = "${WORKDIR}"

inherit systemd

do_compile() {
    oe_runmake
}

do_install() {
    install -d ${D}${bindir} ${D}${libexecdir}/k1os ${D}${sysconfdir}/k1os \
               ${D}${systemd_system_unitdir}/moonraker.service.d
    install -m 0755 ${S}/k1os-stream ${D}${bindir}/
    install -m 0755 ${S}/k1os-twitch ${D}${libexecdir}/k1os/twitch
    install -m 0755 ${S}/k1os-twitch-asvc ${D}${libexecdir}/k1os/twitch-asvc
    # go2rtc's source for the stream "k1" (recipe go2rtc, /etc/go2rtc.yaml)
    install -m 0755 ${S}/k1os-h264-source ${D}${libexecdir}/k1os/h264-source
    install -m 0644 ${S}/k1os-twitch.service ${S}/k1os-twitch-autostart.service ${D}${systemd_system_unitdir}/
    # Moonraker only controls services listed in moonraker.asvc: add ours before it starts.
    install -m 0644 ${S}/moonraker-k1os-twitch.conf ${D}${systemd_system_unitdir}/moonraker.service.d/k1os-twitch.conf
    install -m 0644 ${S}/twitch.env.example ${D}${sysconfdir}/k1os/
    # Moonraker component: loaded as [k1os_stream] from moonraker.conf (the
    # fragment below is appended to an existing moonraker.conf once by
    # k1os-datadir-setup, like the timelapse one).
    install -d ${D}${datadir}/moonraker/moonraker/components ${D}${sysconfdir}/k1os/moonraker.d
    install -m 0644 ${S}/k1os_stream.py ${D}${datadir}/moonraker/moonraker/components/
    python3 -m compileall -q -s ${D} -p / ${D}${datadir}/moonraker/moonraker/components/k1os_stream.py || true
    install -m 0644 ${S}/k1os-stream.conf ${D}${sysconfdir}/k1os/moonraker.d/k1os-stream.conf
    # Klipper macros TWITCH, TWITCH_START/STOP/SET/LOGIN/STATUS; k1os_kalico.cfg
    # includes /usr/share/k1os/stream.cfg.
    install -d ${D}${datadir}/k1os
    install -m 0644 ${S}/k1os_stream.cfg ${D}${datadir}/k1os/stream.cfg
}

# The stream is started from Mainsail (Services menu) or, with
# TWITCH_AUTOSTART=1 in twitch.env, by the autostart unit at boot.
SYSTEMD_SERVICE:${PN} = "k1os-twitch-autostart.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"
FILES:${PN} += "${systemd_system_unitdir}/k1os-twitch.service"

FILES:${PN} += "${libexecdir}/k1os ${systemd_system_unitdir} ${datadir}/k1os ${datadir}/moonraker"
RDEPENDS:${PN} += "ffmpeg ustreamer moonraker python3-jinja2"
