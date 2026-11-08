SUMMARY = "Datel OS: open-source firmware image for the Creality K1"
LICENSE = "MIT"

inherit core-image

IMAGE_FEATURES += "read-only-rootfs ssh-server-openssh"

IMAGE_INSTALL = " \
    packagegroup-core-boot \
    kernel-modules \
    linux-firmware-bcm43430 k1-wifi-nvram wireless-regdb-static \
    wpa-supplicant iw \
    e2fsprogs-e2fsck \
    mtd-utils \
    python3 python3-pyserial \
    k1os-base datel-branding \
"

# Printing stack: Creality's Klipper (fits the stock MCU firmware), Moonraker,
# Mainsail on nginx and Guppy Screen on the touch display.
# K1OS_KLIPPER picks the printing stack: "klipper-creality" (Creality's fork
# with the stock MCU firmware) or "kalico" (pellcorp's Kalico with our own
# MCU firmware and the load cell probe).
K1OS_KLIPPER ?= "klipper-creality"
IMAGE_INSTALL += "${K1OS_KLIPPER} moonraker mainsail guppyscreen nginx ustreamer"
# Timelapse: moonraker-timelapse with the render step on the X2000 Helix codec
# (k1os-helix, pulls in ffmpeg for the MP4 muxing).
IMAGE_INSTALL += "moonraker-timelapse k1os-helix"
# Twitch live stream with a status overlay (k1os-stream on the Helix codec, ffmpeg for RTMP).
IMAGE_INSTALL += "k1os-stream"

IMAGE_ROOTFS_EXTRA_SPACE = "0"

# The stock bootloader passes init=/linuxrc on the kernel command line.
k1os_linuxrc() {
    ln -sf /sbin/init ${IMAGE_ROOTFS}/linuxrc
}
ROOTFS_POSTPROCESS_COMMAND += "k1os_linuxrc;"
