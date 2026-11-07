SUMMARY = "Wi-Fi NVRAM for the Creality K1 (AP6212A / CYW43438)"
DESCRIPTION = "Board calibration data for brcmfmac. The firmware itself comes from \
linux-firmware (brcmfmac43430-sdio.bin). This file is vendor data, not code."
# Vendor calibration data from the Ingenic SDK and the stock K1 firmware, no stated license.
LICENSE = "CLOSED"

SRC_URI = "file://nvram-ap6212a-k1.txt"
S = "${WORKDIR}"

inherit allarch

# brcmfmac asks for brcmfmac43430-sdio.<first DT compatible>.txt first and then
# for the generic name; both lead to the K1 file.
do_install() {
    install -d ${D}${nonarch_base_libdir}/firmware/brcm
    install -m 0644 ${WORKDIR}/nvram-ap6212a-k1.txt \
        "${D}${nonarch_base_libdir}/firmware/brcm/brcmfmac43430-sdio.creality,k1.txt"
    ln -sf "brcmfmac43430-sdio.creality,k1.txt" \
        ${D}${nonarch_base_libdir}/firmware/brcm/brcmfmac43430-sdio.txt
}

FILES:${PN} = "${nonarch_base_libdir}/firmware/brcm"
RDEPENDS:${PN} = "linux-firmware-bcm43430"
