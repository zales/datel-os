SUMMARY = "Linux 6.6 for the Ingenic X2000 (Creality K1)"
DESCRIPTION = "Ingenic's X2000 SDK kernel 6.6 with PREEMPT_RT, as maintained by NebulaOS \
for the Ender-3 V3 KE, plus a Creality K1 board device tree."
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

# Plain kernel class: kernel-yocto assumes the kernel is the repository root,
# but here it is a subdirectory of the SDK repository.
inherit kernel

# The repository is the whole Ingenic SDK (kernel, u-boot, buildroot, tools);
# the kernel lives in kernel/kernel-6.6.
SRC_URI = "git://github.com/NebulaOS-KE/NebulaOS-kernel.git;protocol=https;branch=openke \
           file://creality_k1.dts \
           file://k1.cfg \
           file://0001-helix-rc-none.patch \
           file://0002-helix-no-MAX-MIN-redefinition.patch \
           file://0003-helix-rc-none-frame-setup.patch \
           file://0004-clk-x2000-an-option-for-the-CPU-clock.patch \
          "
SRCREV = "d86790d2e23178e52054c71562f9c40994a5469b"
S = "${WORKDIR}/git/kernel/kernel-6.6"

LINUX_VERSION = "6.6.157"
LINUX_VERSION_EXTENSION = "-k1"
PV = "${LINUX_VERSION}+git${SRCPV}"

COMPATIBLE_MACHINE = "creality-k1"

# Config = NebulaOS's X2000 defconfig + the K1 fragment (later lines win);
# kernel_do_configure turns ${WORKDIR}/defconfig into .config via olddefconfig.
# The board DT is built into the kernel by the Ingenic module_drivers build
# (CONFIG_DT_X2000_MODULE_BASE_DTS_FILE, see k1.cfg).
# cfg80211 is built in and loads regulatory.db one second into the boot, long
# before the root filesystem is mounted; the copy in /lib/firmware comes too
# late. Built into the kernel, the database is there in time. It comes from
# wireless-regdb, the same files the image installs.
DEPENDS += "wireless-regdb"
REGDB_DIR = "${STAGING_DIR_HOST}${nonarch_base_libdir}/firmware"

do_configure:prepend() {
    install -m 0644 ${WORKDIR}/creality_k1.dts ${S}/module_drivers/dts/x2000/creality_k1.dts
    cat ${S}/arch/mips/configs/nebulaos_halley5_v30_defconfig ${WORKDIR}/k1.cfg > ${WORKDIR}/defconfig
    [ -f ${REGDB_DIR}/regulatory.db ] && [ -f ${REGDB_DIR}/regulatory.db.p7s ] || bbfatal "regulatory.db is missing in ${REGDB_DIR}"
    printf '%s\n' 'CONFIG_EXTRA_FIRMWARE="regulatory.db regulatory.db.p7s"' \
        'CONFIG_EXTRA_FIRMWARE_DIR="${REGDB_DIR}"' >> ${WORKDIR}/defconfig
    rm -f ${B}/.config
}

# The only binary in this kernel is the X2000 fast-resume stub that
# pm_fastboot.c #includes as fastboot_resume_code.hex. Its source ships in
# pm_firmware/fastboot_firmware, so rebuild it here instead of using the
# vendor's prebuilt copy. CREALITY_K1_FASTBOOT_PREBUILT = "1" restores the
# vendor file.
CREALITY_K1_FASTBOOT_PREBUILT ??= "0"
do_configure:append() {
    fw=${S}/arch/mips/xburst2/soc-x2000/pm_firmware/fastboot_firmware
    hex=${S}/arch/mips/xburst2/soc-x2000/fastboot_resume_code.hex
    [ -f ${hex}.vendor ] || cp ${hex} ${hex}.vendor
    if [ "${CREALITY_K1_FASTBOOT_PREBUILT}" = "1" ]; then
        cp ${hex}.vendor ${hex}
    else
        # The vendor "clean" target fails on a clean tree (rm without -f).
        rm -f $fw/src/*.o $fw/*.o $fw/*.bin $fw/*.elf $fw/*.map $fw/*.dump $fw/fastboot_resume_code.hex
        make -C $fw CC="${TARGET_PREFIX}gcc" LD="${TARGET_PREFIX}ld.bfd" \
            OBJCOPY="${TARGET_PREFIX}objcopy" OBJDUMP="${TARGET_PREFIX}objdump"
        cp $fw/fastboot_resume_code.hex ${hex}
        if cmp -s ${hex} ${hex}.vendor; then
            bbnote "fastboot_resume_code.hex rebuilt from source; identical to the vendor copy"
        else
            bbwarn "fastboot_resume_code.hex rebuilt from source; differs from the vendor copy"
        fi
    fi
}

# Fail the build if the K1 settings did not survive olddefconfig.
do_configure:append() {
    for opt in CONFIG_DT_X2000_MODULE_BASE=y 'CONFIG_DT_X2000_MODULE_BASE_DTS_FILE="x2000/creality_k1.dts"' \
               CONFIG_SQUASHFS_XZ=y CONFIG_TOUCHSCREEN_GOODIX=y CONFIG_BRCMFMAC=m 'CONFIG_EXTRA_FIRMWARE="regulatory.db regulatory.db.p7s"' \
               CONFIG_LRU_GEN=y CONFIG_LRU_GEN_ENABLED=y CONFIG_ZRAM=y \
               CONFIG_VIDEO_INGENIC_VCODEC=y CONFIG_INGENIC_HELIX=y CONFIG_INGENIC_HELIX_H264E_RC_NONE=y; do
        grep -qx "$opt" ${B}/.config || bbfatal "kernel config is missing $opt"
    done
}

# xImage is a legacy U-Boot image (mkimage) of a self-decompressing zImage,
# built in arch/mips/boot/zcompressed/; kernel.bbclass expects it in arch/mips/boot.
DEPENDS += "u-boot-tools-native"
do_compile:append() {
    cp ${B}/arch/mips/boot/zcompressed/xImage ${B}/arch/mips/boot/xImage
}
