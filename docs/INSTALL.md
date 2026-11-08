# Installing Datel OS

Datel OS is written over SSH into the eMMC slot the printer is not running from. Stock runs from slot 1 (kernel `mmcblk0p5`, system `mmcblk0p7`); the first install goes into slot 2 (`mmcblk0p6`, `mmcblk0p8`). Nothing else on the eMMC is touched: the bootloader, the RTOS of the third core and the stock system in slot 1 stay as they are.

## Before you start

- A K1 with mainboard CR4CU220812S11 or S12 running stock firmware 1.3.x. Verified on one printer; see [Limitations](../README.md#limitations).
- Root over SSH on stock. Creality publishes the root password in its rooting guide. Copy your key once; Datel OS takes it over from `/usr/data/k1os/ssh/authorized_keys`:

```bash
ssh-copy-id -i ~/.ssh/k1_printer_ecdsa.pub root@<ip>
```

- The release files (`gh release download vX.Y.Z -R zales/datel-os -D dl/`, then `shasum -a 256 -c SHA256SUMS` in `dl/`) or your own build, see [DEVELOPMENT.md](DEVELOPMENT.md).
- The printer must not be printing. `tools/flash-slot2.sh` refuses to write while a print runs or is paused.

### Back up the eMMC

Strongly recommended before the first write. Read partitions p1 to p5 and p7 from stock, about 330 MB:

```bash
for p in 1 2 3 4 5 7; do ssh root@<ip> "dd if=/dev/mmcblk0p$p bs=1M" > mmcblk0p$p.bin; done
```

Compare each file's MD5 with `md5sum /dev/mmcblk0pN` on the printer. Going back to stock from a running Datel OS is writing these files back.

## Write the inactive slot

The script runs from the repository checkout. `PRINTER` is the SSH target, `KEY` the private key (default `~/.ssh/k1_printer_ecdsa`), `KERNEL` and `ROOTFS` the images. Without an option it only checks.

1. Check: the right slot runs, the marker is as expected, nothing prints, the images fit the partitions.

```bash
KERNEL=dl/datel-os-vX.Y.Z-xImage ROOTFS=dl/datel-os-vX.Y.Z-kalico.squashfs PRINTER=root@<ip> tools/flash-slot2.sh
```

2. Write both partitions, read them back and compare the MD5. The marker is not touched.

```bash
KERNEL=dl/datel-os-vX.Y.Z-xImage ROOTFS=dl/datel-os-vX.Y.Z-kalico.squashfs PRINTER=root@<ip> tools/flash-slot2.sh --write
```

3. Point the boot marker in `mmcblk0p1` at the new slot.

```bash
KERNEL=dl/datel-os-vX.Y.Z-xImage ROOTFS=dl/datel-os-vX.Y.Z-kalico.squashfs PRINTER=root@<ip> tools/flash-slot2.sh --switch
```

4. Restart. From stock **power the printer off and on** (the MCU firmware changes only on a cold start). From a running Datel OS a `reboot` is enough.

Pick the system variant with `ROOTFS`: `…-kalico.squashfs` (Kalico, open MCU firmware, recommended) or `…-klipper-creality.squashfs` (Creality's Klipper, stock MCU firmware). Both use the same kernel image.

## Trial boot and keeping a slot

Datel OS boots as a trial. Its first step, before any file system is mounted, points the marker back at the other slot. If anything hangs after that, a power cycle brings the previous system back. The new slot stays only after:

```bash
ssh root@<ip> k1os-slot keep
```

`k1os-slot status` shows the running slot, the next boot and whether keep is set; `k1os-slot release` undoes it. The keep flag lives in `/usr/data`, which both slots share, so a later update into the other slot inherits it.

What the trial boot does not cover: a kernel that hangs before the first service, for example because of the device tree. Then every boot goes to the new slot and only the USB mask-ROM boot swaps the marker back, see [Recovery](#recovery).

## First start

- The IP address may change. Datel OS identifies itself to the DHCP server with the MAC address, like stock, but routers differ. Find the printer by its host name `datel` or by the Moonraker port 7125.
- Wi-Fi settings are copied from stock on the first start (`/usr/data/wpa_supplicant.conf` to `/usr/data/k1os/`). Later changes do not propagate between the systems.
- Mainsail is at `http://<ip>/`. The camera and the printer name are registered automatically.
- **Kalico variant:** the configuration is converted once and the three MCUs get the open firmware on the first cold start, about 10 s. After a warm restart from stock the main MCU stays in shutdown; one `FIRMWARE_RESTART` fixes it. Calibration and fans are described in [KALICO.md](KALICO.md).
- **Slicer:** add `TIMELAPSE_TAKE_FRAME` to the layer change G-code if you want timelapses, see [CAMERA.md](CAMERA.md). OrcaSlicer's device tab needs the camera "K1 (snapshots)".

## Datel OS in both slots

Once Datel OS runs from slot 2 and you are happy with it, the same images can go into slot 1:

```bash
SLOT=1 KERNEL=… ROOTFS=… PRINTER=root@<ip> tools/flash-slot2.sh --write
```

followed by `--switch` and a reboot. `SLOT=` names the target; the script refuses to write into the running slot. From then on A/B serves Datel OS alone: an update goes into the slot that is not running, and the trial boot falls back to the previous Datel OS. Stock is gone from the printer at that point, and with it the display, so keep the backup.

## Going back to stock

- While stock is still in the other slot: power the printer off and on before `k1os-slot keep` was run, or `k1os-slot release` and reboot afterwards. Stock reflashes the MCU firmware itself.
- When both slots hold Datel OS: write the backed-up partitions back from the running Datel OS into the other slot (`ssh root@<ip> "dd of=/dev/mmcblk0p5" < mmcblk0p5.bin`, the same for p7), then `k1os-slot release` and reboot.

## Recovery

If the printer no longer boots from either slot, the Ingenic mask-ROM USB boot loads a bootloader over the mainboard's micro USB port and can swap the marker (`usbboot --swap-ota`) or read and write partitions. Tool and procedure: [tools/usbboot/README.md](../tools/usbboot/README.md). The procedure is written for the K1 but not yet verified on the S12 board.

## The `.ota.img` package

Each release also contains the kernel and system packed in the format of the stock Creality updater (`CR4CU220812S11_ota_img_V9.X.Y.Z.img`). It is built and checked but has not been tried through the stock updater yet. The verified path is `tools/flash-slot2.sh`.
