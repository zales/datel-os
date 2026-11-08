# K1 USB rescue test (read-only)

Tool: [ballaswag/ingenic-usbboot](https://github.com/ballaswag/ingenic-usbboot), commit c65eaa3.
Only `--swap-ota` writes to the eMMC (partition p1). Reading partitions changes nothing.

## Building on a Mac

```bash
brew install libusb pkg-config
git clone https://github.com/ballaswag/ingenic-usbboot.git ~/k1-usbboot
cd ~/k1-usbboot && git checkout c65eaa337cc9fb64fd8a2ea22bcf3f9395c9945c && make
```

## The test

1. Connect the MicroUSB port on the main board to the Mac. The cable must carry data, not just power. The port is on the top edge of the board on the left, the RESET and BOOT buttons on the same edge on the right (figure 3 in the [Creality guide](https://wiki.creality.com/en/k1-flagship-series/k1/quick-start-guide/brick-rescue-wire-brushing-process)).
2. The printer must be switched on; the board needs its 24 V supply. Do not print, the buttons reset it.
3. Hold BOOT and RESET for about 3 s, release RESET and then BOOT. The system LED glows faintly and the board waits in mask-ROM mode.
4. On the Mac check that the board shows up as "Ingenic USB BOOT DEVICE" (a108:eaef):

```bash
system_profiler SPUSBDataType | grep -i -A3 ingenic
```

Then continue by reading p1:
5. Start U-Boot in RAM and read partition p1 (offset 0x100000, 1 MiB):

```bash
cd ~/k1-usbboot && sudo ./usbboot --uboot && sudo ./usbboot -o 0x100000 -s 0x100000 --dump-partition ./ota.out
```

6. Compare with the backup. Both numbers must be the same:

```bash
md5 -q ~/k1-usbboot/ota.out; dd if=~/Documents/K1-zaloha-2026-11-05/mmcblk0-sectors-0-1488895.bin bs=512 skip=2048 count=2048 2>/dev/null | md5 -q
```

7. Press RESET. The printer starts stock normally.

A match means USB rescue works on this S12 board. A broken slot 2 can then be undone with `sudo ./usbboot --uboot && sudo ./usbboot --swap-ota`.
