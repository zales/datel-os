SUMMARY = "k1os-camera: the camera as MJPEG, snapshots, H.264 over WebRTC and a Twitch stream, in one small daemon"
DESCRIPTION = "Takes the place of uStreamer, go2rtc and of ffmpeg as the RTMP sender. It \
reads the USB camera, serves its JPEG frames (the stream and snapshots Mainsail and the \
timelapse use), and while anyone watches runs k1os-stream's pipeline inside itself: status \
overlay and H.264 on the X2000 Helix codec. That H.264 goes to browsers over WebRTC \
(ICE-lite, SRTP and RTP are its own; the DTLS handshake is mbedtls) and to Twitch over \
RTMP. Also builds h264-to-mp4, which wraps the timelapse's H.264 into an MP4 file. \
Written in Zig; the camera, overlay and codec part is k1os-stream's C, compiled in."
LICENSE = "MIT & (Apache-2.0 | GPL-2.0-or-later) & BSD-2-Clause"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302 \
                    file://mbedtls-${MBEDTLS_PV}/LICENSE;md5=379d5819937a6c2f1ef1630d341e026d \
                    file://LICENSE.spleen;md5=6b0faaab001f2e05d12e136feb82cf71"

MBEDTLS_PV = "3.6.2"
# k1os-stream's sources are compiled into this program as they are
FILESEXTRAPATHS:prepend := "${THISDIR}/../k1os-stream/files:"
SRC_URI = "file://main.zig file://stun.zig file://srtp.zig file://rtp.zig file://rtmp.zig \
           file://publish.zig file://camera.zig file://mp4.zig file://h264-to-mp4.zig \
           file://dtls.c file://cfg/mbedtls_user.h file://build.sh \
           file://k1os-stream.c file://k1os-stream.h file://helix.c file://helix.h \
           file://overlay.c file://overlay.h file://moonraker.c file://moonraker.h \
           file://graph.c file://graph.h file://sysstat.c file://sysstat.h \
           file://font12x24.h file://font16x32.h file://jpeg_dht.h file://LICENSE.spleen \
           https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${MBEDTLS_PV}/mbedtls-${MBEDTLS_PV}.tar.bz2;name=mbedtls \
           file://k1os-camera.service file://k1os-camera-options file://k1os-camera-device"
SRC_URI[mbedtls.sha256sum] = "8b54fb9bcf4d5a7078028e0520acddefb7900b3e66fec7f7175bb5b7d85ccdca"
S = "${WORKDIR}"

DEPENDS = "zig-native"
inherit systemd

do_configure[noexec] = "1"

# Zig compiles everything itself, for the K1's ABI and statically against its
# own musl (build.sh says why); the Yocto compiler is not used. The unit
# tests run first, on the build host, linked against that musl too.
do_compile() {
    export ZIG_GLOBAL_CACHE_DIR=${WORKDIR}/zig-global-cache
    export ZIG_LOCAL_CACHE_DIR=${WORKDIR}/zig-local-cache
    cd ${S}
    zig test main.zig -target ${BUILD_ARCH}-linux-musl -lc
    zig test h264-to-mp4.zig -target ${BUILD_ARCH}-linux-musl -lc
    MBEDTLS=${WORKDIR}/mbedtls-${MBEDTLS_PV} K1OS_STREAM=${S} sh ${S}/build.sh
}

do_install() {
    install -d ${D}${bindir} ${D}${libexecdir}/k1os ${D}${systemd_system_unitdir}
    install -m 0755 ${S}/build/k1os-camera ${D}${bindir}/k1os-camera
    install -m 0755 ${S}/build/h264-to-mp4 ${D}${bindir}/h264-to-mp4
    install -m 0755 ${WORKDIR}/k1os-camera-options ${D}${libexecdir}/k1os/camera-options
    install -m 0755 ${WORKDIR}/k1os-camera-device ${D}${libexecdir}/k1os/camera-device
    install -m 0644 ${WORKDIR}/k1os-camera.service ${D}${systemd_system_unitdir}/
}

SYSTEMD_SERVICE:${PN} = "k1os-camera.service"
FILES:${PN} += "${libexecdir}/k1os"
# static, and stripped by Zig
INSANE_SKIP:${PN} += "already-stripped"
