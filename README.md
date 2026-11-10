<img src="docs/logo.svg" width="96" align="right" alt="Datel OS">

# Datel OS

Open firmware for the Creality K1, built from source with Yocto: Linux 6.6-rt, Kalico with open firmware for all three MCUs, Moonraker, Mainsail, camera streaming, hardware-encoded timelapse and Twitch live streaming. The stock bootloader stays in place and the second eMMC slot always holds a way back.

**Pre-release for developers.** Version 0.2.0 runs and prints on the author's K1 in both A/B slots. The display does not work yet, recovery from a kernel that fails to boot needs a USB cable, and everything is verified on one printer. Read [Limitations](#limitations) before installing.

## What works

| Area | State |
|---|---|
| Kernel | Linux 6.6.157 PREEMPT_RT (Ingenic X2000, NebulaOS tree) with a K1 device tree: eMMC, Wi-Fi with the stock MAC, all three MCU UARTs, UVC camera, Helix video codec |
| System | Yocto scarthgap, systemd, read-only squashfs root, data in `/usr/data/k1os`, A/B slots with a trial boot that falls back to the other slot |
| Printing | Kalico with open firmware on all three MCUs, load cell probe, verified prints |
| Web UI | Moonraker and Mainsail behind nginx, printer name and camera registered on first boot |
| Camera | 720p MJPEG through uStreamer, H.264 over WebRTC through go2rtc from the Helix codec (shared with the Twitch stream), a snapshot camera for slow links |
| Timelapse | moonraker-timelapse with the render on the X2000 Helix hardware encoder |
| Twitch | Live stream with a status bar and temperature graph in the picture, controlled from Mainsail, automatic stream title |
| Updates | Write the inactive slot over SSH, trial boot, GitHub Releases from tags |
| Display and touch | **Missing.** The screen shows the RTOS boot logo only |
| Own bootloader | In progress on branch `feat/uboot`, not verified on the printer |

## Limitations

Ordered by how much it hurts.

1. **No display.** Datel OS has no panel driver. Control the printer through Mainsail, OrcaSlicer or SSH.
2. **No automatic fallback from a kernel that does not boot.** The stock SPL has no boot counter. The trial boot protects from the first systemd service on; a kernel that hangs before that needs the USB mask-ROM boot ([tools/usbboot/README.md](tools/usbboot/README.md)), not yet verified on the S12 board.
3. **Installation needs root over SSH on stock.** Creality publishes the stock root password in its rooting guide. Datel OS keeps the same root password, so it opens both slots.
4. **MCU firmware changes only on a cold start.** When moving between stock and Datel OS, power the printer off and on.
5. **Verified on one printer:** board CR4CU220812S11, panel `lcm_id=3`.
6. **Wi-Fi is 2.4 GHz only.** The camera stream can saturate a weak link; the default is 8 fps.

## Install

Short version; the full procedure with backup, recovery and first-start steps is in [docs/INSTALL.md](docs/INSTALL.md).

1. Copy your SSH key to the stock printer: `ssh-copy-id -i ~/.ssh/k1_printer_ecdsa.pub root@<ip>`.
2. Download a [release](https://github.com/zales/datel-os/releases) and verify `SHA256SUMS`, or build (below).
3. Write the inactive slot and verify it:

```bash
KERNEL=dl/datel-os-vX.Y.Z-xImage ROOTFS=dl/datel-os-vX.Y.Z-rootfs.squashfs PRINTER=root@<ip> tools/flash-slot2.sh --write
```

4. Point the boot marker at the new slot and power-cycle the printer:

```bash
KERNEL=dl/datel-os-vX.Y.Z-xImage ROOTFS=dl/datel-os-vX.Y.Z-rootfs.squashfs PRINTER=root@<ip> tools/flash-slot2.sh --switch
```

Datel OS starts in trial mode: a power cycle returns to the previous system until you run `k1os-slot keep` on the printer.

## Build

Needs Docker. The build tree lives in the Docker volume `k1yocto-work` because Yocto needs a case-sensitive file system. The first build takes hours; later ones minutes.

```bash
./build.sh
```

Images land in the volume under `build/tmp/deploy/images/creality-k1/`; `TAG=vX.Y.Z tools/release.sh collect` copies them out. Details in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Documentation

| Document | Contents |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | Backup, flashing, trial boot, both slots, going back to stock, recovery |
| [docs/KALICO.md](docs/KALICO.md) | Kalico and the MCU firmware: configuration conversion, probe and input shaper calibration, fans |
| [docs/CAMERA.md](docs/CAMERA.md) | Camera settings, OrcaSlicer, timelapse |
| [docs/TWITCH.md](docs/TWITCH.md) | Twitch live stream: setup, Mainsail dialog, overlay, automatic title |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Layer layout, build, kernel and image internals, design decisions |
| [docs/HARDWARE.md](docs/HARDWARE.md) | K1 hardware as found on the stock system: partitions, pins, peripherals |
| [docs/RELEASE.md](docs/RELEASE.md) | Release files, the build runner, cutting a release |
| [docs/NOTES.md](docs/NOTES.md) | Engineering log: findings and measurements by date |

## Repository layout

| Path | Contents |
|---|---|
| `meta-creality-k1/` | The Yocto layer: machine and distro, kernel recipe with the K1 device tree, printer software, Datel OS services |
| `kas-creality-k1.yml` | kas configuration of the build |
| `build.sh` | Builds in Docker |
| `tools/` | `flash-slot2.sh` (install over SSH), `release.sh`, `shaper-fit.sh`, `rtos-splash.py`, `usbboot/` |
| `hardware/` | Stock device tree, module parameters and live GPIO state of the reference printer |
| `docs/` | Documentation |

## Licensing

Our code, recipes, scripts, documentation and artwork are under the MIT license ([LICENSE](LICENSE)). The image contains third-party software under its own licenses; every recipe in `meta-creality-k1` names its license and exact source.

| Component | License | Source |
|---|---|---|
| Linux 6.6 (Ingenic X2000, NebulaOS) | GPL-2.0 | [NebulaOS-KE/NebulaOS-kernel](https://github.com/NebulaOS-KE/NebulaOS-kernel) |
| Kalico host and MCU firmware | GPL-3.0 | [pellcorp/kalico](https://github.com/pellcorp/kalico), [pellcorp/k1-kalico-firmware](https://github.com/pellcorp/k1-kalico-firmware) |
| Moonraker, Mainsail, moonraker-timelapse | GPL-3.0 | upstream |
| uStreamer | GPL-3.0 | [pikvm/ustreamer](https://github.com/pikvm/ustreamer) |
| go2rtc 1.9.15 (built from source, one patch: a byte limit on the queue for a slow viewer) | MIT | [AlexxIT/go2rtc](https://github.com/AlexxIT/go2rtc) |
| ffmpeg 6.1 (muxing only, no x264) | LGPL-2.1 / GPL-2.0 | poky |
| Spleen bitmap font | BSD-2-Clause | [fcambus/spleen](https://github.com/fcambus/spleen) |
| GuppyScreen | GPL-3.0, MIT, BSD-3 | upstream |
| Wi-Fi firmware `brcmfmac43430-sdio.bin` | linux-firmware license (binary) | linux-firmware |
| AP6212A NVRAM | vendor calibration data, no stated license | Ingenic SDK / stock firmware |
| Yocto poky, meta-openembedded | MIT and per-package licenses | upstream |

Neither the image nor a release contains the stock bootloader (SPL, U-Boot), the RTOS `zero.bin` of the third core, or the contents of partition `mmcblk0p9`. Nothing is taken from the unlicensed pellcorp/creality repository.
