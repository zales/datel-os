SUMMARY = "K1 OS: open-source firmware image for the Creality K1"
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
    k1os-base \
"

# Printing stack: Creality's Klipper (fits the stock MCU firmware), Moonraker,
# Mainsail on nginx and Guppy Screen on the touch display.
IMAGE_INSTALL += "klipper-creality moonraker mainsail guppyscreen nginx ustreamer"

IMAGE_ROOTFS_EXTRA_SPACE = "0"

# The stock bootloader passes init=/linuxrc on the kernel command line.
k1os_linuxrc() {
    ln -sf /sbin/init ${IMAGE_ROOTFS}/linuxrc
}
ROOTFS_POSTPROCESS_COMMAND += "k1os_linuxrc;"
