SUMMARY = "go2rtc: camera streaming server (WebRTC, MSE, MP4)"
DESCRIPTION = "go2rtc serves the camera's H.264 (k1os-stream on the Helix codec) to \
Mainsail's WebRTC player and to the Twitch stream, from one encoder that runs only \
while someone watches. Built from source because of one patch: upstream queues up \
to 4096 frames for a WebRTC viewer on a slow network, which is more than the K1's RAM."
HOMEPAGE = "https://github.com/AlexxIT/go2rtc"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=84f39ec0f1c900532a719dbb9ef7dfd3"

SRC_URI = "git://github.com/AlexxIT/go2rtc.git;protocol=https;nobranch=1 \
           file://0001-core-limit-the-bytes-a-Sender-queues-for-a-slow-consumer.patch \
           file://go2rtc.yaml \
           file://go2rtc.service"
# v1.9.15
SRCREV = "7c05066c90ab6ad1fccb506d5f0408aa31ebe60f"
S = "${WORKDIR}/git"

inherit systemd

# go2rtc needs Go 1.26 and scarthgap has 1.22. Go fetches the toolchain a
# module asks for by itself (GOTOOLCHAIN), so go-native only has to start the
# build; the toolchain and the modules come from proxy.golang.org and are
# checked against the Go checksum database. That is why do_compile needs the
# network.
DEPENDS = "go-native"
GO2RTC_GOTOOLCHAIN ?= "go1.26.10"
do_compile[network] = "1"

# Pure Go, static. GOMIPS is left at its default (hardfloat), like the
# upstream release for linux/mipsle. Unlike that release the binary is not
# packed with UPX: squashfs compresses it anyway, and an unpacked binary is
# paged in from the image instead of being unpacked into RAM.
do_compile() {
    export GOOS=linux GOARCH=mipsle CGO_ENABLED=0
    export GOTOOLCHAIN=${GO2RTC_GOTOOLCHAIN}
    export GOPATH=${WORKDIR}/gopath GOCACHE=${WORKDIR}/gocache
    export GOPROXY=https://proxy.golang.org,direct
    export GOFLAGS="-modcacherw -trimpath -buildvcs=false"
    cd ${S}
    go build -ldflags "-s -w" -o ${B}/go2rtc .
    # The downloaded toolchain is unpacked read-only (-modcacherw covers the
    # modules only); rm_work has to be able to delete it.
    chmod -R u+w ${WORKDIR}/gopath
}

do_install() {
    install -D -m 0755 ${B}/go2rtc ${D}${bindir}/go2rtc
    install -D -m 0644 ${WORKDIR}/go2rtc.yaml ${D}${sysconfdir}/go2rtc.yaml
    install -D -m 0644 ${WORKDIR}/go2rtc.service ${D}${systemd_system_unitdir}/go2rtc.service
}

SYSTEMD_SERVICE:${PN} = "go2rtc.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# A static Go binary, linked with -s -w: nothing to strip or split.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INHIBIT_SYSROOT_STRIP = "1"
INSANE_SKIP:${PN} += "already-stripped ldflags"

# The stream "k1" runs /usr/libexec/k1os/h264-source from k1os-stream.
RDEPENDS:${PN} += "k1os-stream"
