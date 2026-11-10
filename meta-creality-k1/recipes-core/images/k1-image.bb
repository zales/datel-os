SUMMARY = "Datel OS: open-source firmware image for the Creality K1"
LICENSE = "MIT"

inherit core-image extrausers

IMAGE_FEATURES += "read-only-rootfs ssh-server-openssh"

# Root keeps the stock firmware's password (the hash is copied from /etc/shadow of
# the stock rootfs on mmcblk0p7; Creality publishes the password in its rooting guide),
# so one password opens both slots. The root is read-only: passwd cannot change it
# on the printer, only here. The hash goes through a double-quoted shell string in
# extrausers.bbclass, so every $ is escaped or the shell eats $5, $do2Fx5 and $8.
EXTRA_USERS_PARAMS = "usermod -p '\$5\$do2Fx5.o9ndk\$8EchNjZMu2F.uTPtRnsr8QiZOFfS488o7dz9cjsMO66' root;"

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

# Printing stack: Kalico (pellcorp's tree with the K1 load cell probe) with our
# own firmware for the three MCUs, Moonraker, Mainsail on nginx and Guppy
# Screen on the touch display.
IMAGE_INSTALL += "kalico moonraker mainsail guppyscreen nginx ustreamer"
# Timelapse: moonraker-timelapse with the render step on the X2000 Helix codec
# (k1os-helix, pulls in ffmpeg for the MP4 muxing).
IMAGE_INSTALL += "moonraker-timelapse k1os-helix"
# Twitch live stream with a status overlay (k1os-stream on the Helix codec, ffmpeg for RTMP).
IMAGE_INSTALL += "k1os-stream"
# The camera as H.264 over WebRTC in Mainsail, from the same encoder as Twitch.
IMAGE_INSTALL += "go2rtc"

IMAGE_ROOTFS_EXTRA_SPACE = "0"

# The stock bootloader passes init=/linuxrc on the kernel command line.
k1os_linuxrc() {
    ln -sf /sbin/init ${IMAGE_ROOTFS}/linuxrc
}
ROOTFS_POSTPROCESS_COMMAND += "k1os_linuxrc;"
