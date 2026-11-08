<img src="docs/logo.svg" width="96" align="right" alt="Datel OS">

# Datel OS: open firmware for the Creality K1, built with Yocto

The goal is a system built entirely from source: kernel, userspace, Klipper, Moonraker, the web UI, the display application and the firmware of all three MCUs. The stock bootloader stays in place, so the second set of partitions can always hold a way back.

## Status (8 November 2026)

Datel OS 0.2.0 "first-tap" runs on the author's K1 in both A/B slots and prints. Stock Creality firmware is no longer on that printer (a backup of its partitions exists). The public release is for now a **pre-release for developers**: the printer has no working display, and a kernel that fails to boot can only be recovered over USB.

| Part | Status |
|---|---|
| Kernel 6.6.157-rt, K1 device tree | Runs on the printer: eMMC, Wi-Fi with the stock MAC, UARTs of all three MCUs, UVC camera |
| System (Yocto scarthgap, systemd, read-only root) | Runs; data in `/usr/data/k1os` (p10), A/B slots p5/p7 and p6/p8, trial boot that falls back to the other slot |
| Klipper + MCUs | **Kalico** with its own firmware on all three MCUs (GPL, from `pellcorp/k1-kalico-firmware`), load cell probe, two verified prints; alternatively Creality's Klipper with the stock MCU firmware |
| Moonraker, Mainsail, camera | Served by nginx; 720p MJPEG camera through uStreamer, a second entry for OrcaSlicer's embedded browser |
| Branding | hostname `datel`, MOTD with the printer's state, prompt, logo and favicon in Mainsail, boot logo in the RTOS (by a tool outside the image) |
| Releases | tag `vX.Y.Z` → build on a self-hosted runner → GitHub Release (xImage, squashfs of both variants, `.ota.img`, SHA256SUMS) |
| Display driver and touch | **Missing.** The screen shows only the RTOS boot logo; GuppyScreen waits for `/dev/fb0` |
| Own bootloader | In progress on branch `feat/uboot`, not verified on the printer; the stock SPL/U-Boot stays |
| Install through the stock updater (`.ota.img`) | The package is built, not tried on the printer; the verified path is `tools/flash-slot2.sh` |

## Limitations and risks

Read before installing. Ordered by how much it hurts.

1. **The display is dead.** Datel OS has no panel driver; the RTOS logo stays on the screen after boot. Control only through Mainsail, OrcaSlicer or SSH.
2. **A kernel failure has no automatic fallback.** The stock SPL has no boot counter; the Datel OS trial mode protects only from the first systemd service on. If the new kernel does not run, the only way back is the USB mask-ROM boot (`tools/usbboot/README.md`), not yet verified on the S12 board. The kernel in a release is the one the author runs, so the risk is small, but not zero.
3. **Installation needs root over SSH on stock.** Creality publishes the stock root password in its rooting guide; `tools/flash-slot2.sh` logs in with a key that you first copy to stock (`ssh-copy-id`).
4. **MCU firmware changes only on a cold start.** After a plain system reboot the MCUs still run the old firmware and Kalico cannot connect; when moving between stock and Datel OS, power the printer off and on.
5. **Verified on one printer.** A K1 with board CR4CU220812S11 and panel `lcm_id=3`, two ABS prints, the X axis input shaper looks suspicious (weak transmission), the probe calibration of one unit serves as defaults.
6. **Wi-Fi is 2.4 GHz only** (AP6212A module) and the camera can saturate the link; the default is 8 fps.

## What it is built on

- **Kernel:** Ingenic X2000 SDK, Linux 6.6.157 with PREEMPT_RT, from [NebulaOS-KE/NebulaOS-kernel](https://github.com/NebulaOS-KE/NebulaOS-kernel), branch `openke`. NebulaOS runs an open firmware for the Ender-3 V3 KE on it, which has the same chip and mostly the same wiring. Commit d86790d is the one NebulaOS-firmware 1.0 pins. It contains all 8 of their fixes that used to be applied by build scripts: PREEMPT_RT, in-band IRQ and high-speed SDIO for Wi-Fi, display VSYNC, a pinctrl fix, backlight control, PWM state readback, the NS2009 touch driver and roaming disabled in brcmfmac. Since 3 October 2026 they are commits in the kernel (NebulaOS-firmware b93415a). The configuration differs from NebulaOS only where the K1 needs it: the K1 device tree, Goodix, Bluetooth, XZ squashfs and brcmfmac as a module with its firmware in the rootfs.
- **K1 board support:** the device tree `creality_k1.dts` takes the KE board and changes what differs on the K1: console, MCU UARTs, touch, display, Wi-Fi and Bluetooth pins. Every value points at the stock file it came from.
- **System:** Yocto scarthgap (poky, meta-oe, meta-python, meta-networking), systemd, read-only root.
- **Update package:** the image type `creality-ota` produces an `.img` that the stock updater and a future own updater install. It holds the kernel and the system squashfs and goes into the inactive set of partitions.

## Build

The simplest way is `./build.sh`; the result lands in a Docker volume together with the log `build-last.log`. Releases (tag `vX.Y.Z` → GitHub Release with images) are described in [docs/RELEASE.md](docs/RELEASE.md).

It needs Docker. The build has to run on a case-sensitive file system, which is why the work directory lives in a Docker volume.

```bash
docker volume create k1yocto-work
docker run --rm -u root -v k1yocto-work:/work -v "$PWD":/src:ro --entrypoint bash ghcr.io/siemens/kas/kas:4.7 -c \
  'mkdir -p /work/k1-yocto && cp -r /src/meta-creality-k1 /src/kas-creality-k1.yml /work/k1-yocto/ && chown -R builder:builder /work &&
   su builder -c "cd /work/k1-yocto && KAS_WORK_DIR=/work/k1-yocto kas build kas-creality-k1.yml"'
```

## Pitfalls known up front

- **The bootloader passes `init=/linuxrc`.** The image therefore creates `/linuxrc` as a link to `/sbin/init`.
- **The bootloader selects the display type** through the `lcm_id` parameter. This printer has `lcm_id=3`, the ST7701 "tjc" panel. Five more panel variants exist.
- **Partition `mmcblk0p9` is the writable overlay of stock** and holds your modifications. Datel OS must not mount it. It keeps its data only in `/usr/data/k1os`.
- **The RTOS for the third core (`zero.bin`) is closed.** The Datel OS package does not contain it and the slot keeps the existing one. It is a FreeRTOS with an ST7701 panel driver and a JPEG decoder; its only visible job is the logo on the display before Linux comes up. The images (one per panel orientation) sit in it as JPEGs with a symbol table and the SPL does not check the image, so `tools/rtos-splash.py` can replace them in place with the Datel OS logo (same length, zero padded): `dd if=/dev/mmcblk0p4 bs=1M count=4 of=p4.bin` → `tools/rtos-splash.py p4.bin p4-datel.bin` → write back only to p4 (the Datel OS slot), keep the original for the way back.
- **The Wi-Fi chip firmware is a binary** (cyfmac43430 from linux-firmware). There is no other way. The NVRAM (radio calibration) is the AP6212A module file from stock, the same as in the Ingenic SDK, only with `ccode=CN`. The recipe `k1-wifi-nvram` installs it as `brcmfmac43430-sdio.creality,k1.txt` and the generic name points at it.
- **The Wi-Fi regulatory database** (`wireless-regdb-static`) is in the image, so the kernel uses the country from `wpa_supplicant.conf`.
- **Wi-Fi settings come from stock.** On the first start `/usr/data/wpa_supplicant.conf` is copied to `/usr/data/k1os/`. Later changes do not propagate between the systems.
- **The MAC address is the same as on stock.** The `wifi-mac` script reads it before wpa_supplicant starts, first from the `sn_mac` partition, then from `/usr/data/macaddr.txt`. The router therefore gives the printer the same IP.
- **The kernel contains no foreign binary.** The only one, the resume-from-suspend code, is compiled from source in the tree. The build with a newer GCC differs from the shipped binary, but the size matches.

## Verified without flashing (5 November 2026)

Learned from the bootloader backup and by reading the live stock system; nothing on the printer changed.

**Bootloader**
- The SPL already selects the slot by the text in p1 (`ota:kernel` or `ota:kernel2`). It then loads the RTOS of that slot (p3 or p4), the kernel (p5 or p6) and starts it with `root=/dev/mmcblk0p7` or `p8`.
- It has no boot counter and no automatic return to stock. NebulaOS confirms this for the same bootloader on the KE. If the new kernel hangs, it hangs on every boot.
- A full U-Boot 2013.07 is in the image, with `bootdelay=1` and the prompt "Hit any key to stop autoboot". Whether the SPL runs it at all on a normal boot will only be visible on the J1 console.
- The RTOS in slot 2 (p4) has a valid header. The Datel OS package does not overwrite it.
- The stock kernel has no kexec, so a new kernel cannot be tried without a reboot.

**Wi-Fi pins (live stock, `hardware/stock-gpio-live.txt`)**

| Signal | Stock | Datel OS |
|---|---|---|
| Power PA01 | output, 0 (on) | regulator active low, always on |
| WL_REG_ON PE02 | output, 1 | `wlan-reg-on-gpios`, the driver sets 1 |
| Host wake PD05 | input with IRQ | interrupt over SDIO, PD05 in the bcmdhd node |
| 32 kHz PE23 | function clk32k | state `enable` when Wi-Fi turns on (late_initcall from NebulaOS) |
| SDIO msc1 PD08–13 | msc1, 4 bits | `msc1-4bit` |

**Device tree against stock**
- UARTs 1, 2, 3, 5, 7 and 9 have the same pin groups as stock. So do I2C2, I2C4, msc0 and msc1.
- Fixed to match stock: GPE bank voltage 1.8 V (stock has 0x80000003 in register 0x100000E0), PWM without the PC01/PC03 mux and I2C3 disabled, since it sits on the console pins.
- Touch: stock currently has no input device at all. Neither Goodix (0x14) nor tlsc6x (0x2e) bound, because the display of this printer is physically disconnected. Display, touch and GuppyScreen can therefore only be verified once it is connected. The first start does not wait for them.

**Rescue without J1**
- [ballaswag/ingenic-usbboot](https://github.com/ballaswag/ingenic-usbboot) is written for the K1. It loads its own SPL and U-Boot over USB in mask-ROM mode and can swap p1 (`--swap-ota`) or read partitions. It does not use the Creality cloner file, which reportedly fails on S12 boards. Not yet verified on S12.
- A risk-free test: read p1 over USB and compare it with the backup. The procedure is in `tools/usbboot/README.md`.

## Trial start from slot 2

Stock runs from slot 1 and stays there. Datel OS is written into slot 2 (p6 and p8) over SSH with `tools/flash-slot2.sh`.

1. `tools/flash-slot2.sh` only checks: slot 1 is running, the marker is `ota:kernel`, nothing is printing and the images fit.
2. `tools/flash-slot2.sh --write` writes the kernel and the system, reads each partition back and compares the MD5. It adds the public key `~/.ssh/k1_printer_ecdsa.pub` to `/usr/data/k1os/ssh/authorized_keys`. The marker is not touched.
3. `tools/flash-slot2.sh --switch` points the marker in p1 at `ota:kernel2`. Then power the printer off and on.

**Trial mode.** Right at the start of Datel OS (`k1os-trial-boot.service`, before file systems are mounted) the marker is pointed back at `ota:kernel`. If the system hangs anywhere after that, a power cycle is enough and stock comes back. The printer stays on the new system only after `k1os-slot keep`. `k1os-slot status` shows where it runs from and where the next boot goes.

**What this does not protect against:** a kernel hang before the first service starts, for example because of the device tree or the eMMC driver. Then the printer keeps booting into slot 2 and only USB brings it back (`usbboot --swap-ota`, `tools/usbboot/README.md`).

**What gets overwritten:** slot 2, which held an older stock 1.3.3.x; its copy is in the backup `~/Documents/K1-zaloha-2026-11-05`. Since 8 November 2026 Datel OS is in both slots (see step 11 of the Kalico deployment), so `SLOT=` selects which one is overwritten and the script makes sure it never writes into the running one.

## First starts on the printer (7 November 2026)

Datel OS started from slot 2 on the first try: kernel 6.6.157-rt79, eMMC, Wi-Fi with the same MAC as stock, trial mode returning the marker to stock. The faults the first starts exposed, and their fixes:

| What failed | Cause | Fix |
|---|---|---|
| SSH refused the key | poky starts sshd with `sshd_config_readonly` on a read-only system; sshd takes the first value of a keyword | the Datel OS block is at the top of both files (`openssh_%.bbappend`) |
| Different IP (.102) | systemd-networkd identifies itself to the router with a generated ID, not the MAC | `[DHCPv4] ClientIdentifier=mac` in `80-wlan.network` |
| nginx did not run | `listen [::]:80`, the kernel has no IPv6 | line removed from `mainsail.nginx` |
| Moonraker crashed on import | `streaming-form-data` imports `smart_open` | recipe `python3-smart-open` (+ `wrapt` from meta-python) |
| Klipper restarted every 5 s | Creality's `klipper_mcu` does not know `-I`, the unit failed and `Requires=` stopped Klipper | `klipper_mcu -r`, `Wants=` instead of `Requires=` |
| GuppyScreen crashed parsing JSON | it opens the theme for writing, on a read-only root the open fails and it parses an empty stream | themes are copied to `/usr/data/k1os/guppyscreen/themes` on the first start; the service has `ConditionPathExists=/dev/fb0` |

**First print and the FPU (7 November 2026):** the first attempt died on a bug in Creality's `virtual_sdcard.py` (variables without defaults when `user_print_refer.json` is missing; fixed by a sed in the recipe and a copy of the stock settings from `creality/userdata/config` on the first start). The second attempt homed, heated and started printing, but after a few seconds the MCU shut down with "Missed scheduling of next digital out event". Cause: the host Klipper spent 90 % of its time in the kernel, and the counters in `/sys/kernel/debug/mips/fpuemustats` showed 1.7 billion emulated instructions. The XBurst2 FPU has 64-bit registers and only the NaN 2008 encoding; it cannot do the legacy FR=0 mode. The poky tune `mips32r2el`, however, builds the o32 FP32 ABI with legacy NaN, so the kernel emulates every FPU instruction. The stock userspace is compiled with `-mfp64 -mnan=2008` (e_flags 0x70001407). Fix: an own tune `mips32r2el-fp64` (`conf/machine/include/tune-mips32r2el-fp64.inc`) and gcc with `--with-fp-32=64 --with-nan=2008`; this means rebuilding the whole userspace. Side finding: `clock_gettime` costs 12 µs (OST clocksource under a spinlock, no vDSO), against 1.2 µs for a plain syscall.

**Camera (7 November 2026):** the Creality camera (UVC 0c45:6366) delivers MJPEG and H.264 at 1080p30 straight from the hardware. The image contains upstream [pikvm/ustreamer](https://github.com/pikvm/ustreamer) 6.67, which only forwards the MJPEG (`--encoder=HW`); the `ustreamer.service` finds the camera node itself (`camera-device`: the node with index 0 on USB), nginx exposes it at `/webcam/` and `k1os-seed-webcam` registers the camera in Moonraker once, so Mainsail shows it on its own. The default is 1280×720 at 15 fps. The NebulaOS fork is not needed; it handles the raw NV12 of a different camera.

Verified live over SSH: Mainsail through nginx, Moonraker with all components, Klipper `ready` with the main and nozzle MCUs over ttyS7 and ttyS1 (the C helper compiled for MIPS works), temperature readings. `/dev/fb0` is missing because the K1 panel driver does not exist yet.

## The Kalico variant: mainline Klipper and own MCU firmware

A build in place of Creality's Klipper, in `main` since 7 November 2026 and the default on the author's printer.

The image is selected by the variable `K1OS_KLIPPER` (`klipper-creality`, the default, or `kalico`); the Kalico variant is built with `KAS_FILE=kas-creality-k1-kalico.yml ./build.sh`.

| Part | Source | Notes |
|---|---|---|
| Host | [pellcorp/kalico](https://github.com/pellcorp/kalico), branch `aug2026` | Kalico with K1 additions: the strain gauge probe (`load_cell_probe`, `hx711s`), MCU bootloader entry |
| MCU firmware | [pellcorp/k1-kalico-firmware](https://github.com/pellcorp/k1-kalico-firmware), branch `aug2026` | Creality's GD32 port, configurations `.config.mcu/.noz/.bed`; compiled with the `gcc-arm-none-eabi` toolchain from meta-arm. Produces `mcu0_120_G32-mcu0_021_000.bin`, `noz0_120_G30-noz0_026_000.bin`, `bed0_110_G21-bed0_121_000.bin` with the header for the Creality bootloader (version at 0x200, CRC16, length). |
| Flashing | own `k1os-mcu-flash` | the Creality serial bootloader (verified on the printer): 115200 baud, the bootloader waits only about 15 s after power-on; the handshake is a single byte 0x75 and the bootloader accepts it only once, after that it stays up without a time limit and takes only `<command><crc>` frames (version, sector size, sector writes, start application). Whoever talks to it must also send the start, otherwise the MCU never runs the application. A running Klipper cannot be sent into the bootloader (neither the Creality nor the Kalico firmware has `SERIAL_BOOTLOADER_SIDECHANNEL` enabled), so the update happens only after the printer is powered off and on. `k1os-mcu-update.service` runs right after systemd starts, handles all three ports at once (one process each, command `sync`: version, compare, write if needed, start) and skips MCUs that already run the application. Stock reflashes the MCUs itself on the way back. |
| Configuration | `k1os-kalico-config` | converts the stock configuration once: removes `prtouch_v2`, `bl24c16f`, `custom_macro`, `fan_feedback`, switches Z to `probe:z_virtual_endstop`, adds `k1os_kalico.cfg` with the probe, mesh and replacements for the Creality commands (`CX_PRINT_LEVELING_CALIBRATION`, `CX_PRINT_DRAW_ONE_LINE`, `PRTOUCH_READY`, …). A backup of the original configuration stays next to it. |

MCU chips: main board GD32F303xE (120 MHz, `/dev/ttyS7`), nozzle GD32F303xB (120 MHz, `/dev/ttyS1`), leveling GD32E230x8 (72 MHz, `/dev/ttyS9`); all at 230400 baud, application from 0x8003000.

Licensing: Kalico and the firmware are GPL-3.0. The pellcorp/creality repository (installer, configuration fragments, `mcu_util.py`) has no license, so nothing is taken from it; the flasher and the configuration are our own.

The configuration conversion is verified on a copy of the printer's configuration: Kalico loads it without error and stops only at opening the MCU serial port. MCU updates are done by the `k1os-mcu-update` package in both variants: the Creality Klipper variant carries the MCU images from Creality's repository (`004/003/004`), the Kalico variant its own (`021/026/121`), so each loads the firmware it can work with at start.

**Deploying the Kalico variant**
1. From stock: `OUT=out/kalico PRINTER=root@<ip> tools/flash-slot2.sh --write`, `--switch`, restart.
2. On the first start `k1os-kalico-config` converts the configuration (backup next to it in `config.creality-<date>`), `k1os-mcu-update` loads the new firmware into the three MCUs (about 10 s, all at once; only after a cold power-on, after a plain system reboot the old firmware stays and Kalico does not connect to the MCUs), then Kalico comes up.
3. The conversion also seeds the SAVE_CONFIG block with values measured on one K1 (`[load_cell_probe]` counts_per_gram 116.7 and tare, `[input_shaper]` X ei 42.2 Hz / Y mzv 53.2 Hz, unless stock already has them), so the printer homes and meshes right after flashing. Your own calibration is recommended, not required: in Mainsail `LOAD_CELL_DIAGNOSTIC`, then `LOAD_CELL_CALIBRATE` with a weight of about 6 kg (`TARE`, `CALIBRATE GRAMS=6000`, `ACCEPT`, `SAVE_CONFIG`). The values live in the `#*#` block, not in `k1os_kalico.cfg`, because Klipper refuses SAVE_CONFIG when an option exists in both places.
4. `G28`, `PROBE_ACCURACY`, setting the probe `z_offset`, `BED_MESH_CALIBRATE`.
5. The probe runs at 3 mm/s (as repeatable as 1 mm/s, the mesh 40 % faster); the Z axis `homing_speed` is the same so that G28 Z and the mesh share one reference.
6. Input shaper: `SHAPER_CALIBRATE` does not work on the printer (the numpy computation needs more than 256 MB of RAM, the process dies of OOM and Klipper waits for it forever; `systemctl restart klipper` helps). Instead `TEST_RESONANCES AXIS=X OUTPUT=raw_data`, the same for Y, and on the computer `PRINTER=root@<ip> tools/shaper-fit.sh`; write the result into the SAVE_CONFIG block of `printer.cfg`.
7. K1 fans: `fan0` part cooling (nozzle board), `fan1` chamber (rear, with the filter), `fan2` auxiliary side fan. Creality's macros map `M106 P<n>` 1:1, so the auxiliary `P2` from Orca is right; the exhaust (`P3`) would be sent to `fan0` by Creality's macro, so the configuration conversion routes it to `fan1`. The `output_pin` sliders in Mainsail send raw PWM without a minimum (Creality: fan1 from 50/255, fan2 from 180/255), so below that value the fan does not spin.
8. Camera: 720p MJPEG at 15 fps is about 12 Mbit/s and saturates a weak Wi-Fi link (the K1 has 2.4 GHz only, −77 dBm here), then the UI stutters. The default is therefore 8 fps (about 6 Mbit/s) and Mainsail takes the stream directly (`mjpegstreamer`, not adaptive snapshots). Change it in `/usr/data/k1os/camera.env` (`CAMERA_RESOLUTION`, `CAMERA_FPS`) and in Mainsail at the camera. OrcaSlicer's embedded browser (Device tab, WebKit) does not show the MJPEG stream in an image ("Error while connecting to …/webcam/?action=stream"), so Moonraker also has a second camera "K1 (snapshots)" in Adaptive MJPEG-Streamer mode (5 fps); pick it in Orca from the dropdown of the Webcam panel, Mainsail remembers the choice per browser.
9. After a warm restart from stock into Datel OS (the flashing path: `k1os-slot release`, reboot, write, `--switch`, reboot) the main MCU stays in shutdown and Kalico reports "Can not update MCU 'mcu' config as it is shutdown". One `FIRMWARE_RESTART` sorts it out (about 20 s); on a normal Datel OS start it does not happen.
10. The way back: power off and on (trial mode) returns stock, which reflashes the MCU firmware to its own.
11. Both slots with Datel OS: once Datel OS runs from slot 2, `SLOT=1 OUT=out/kalico PRINTER=root@<ip> tools/flash-slot2.sh --write` and `--switch` write the same into slot 1 (p5/p7) and stock disappears from the printer. Back up p1–p5 and p7 first (`dd if=/dev/mmcblk0pN` over SSH, about 330 MB, compare the MD5 with `md5sum /dev/mmcblk0pN` on the printer); the way back to stock is then just writing those files back. From then on A/B serves Datel OS alone: a new version goes into the slot that is not running, and the trial boot falls back to the previous Datel OS on failure. Verified on 8 November 2026: slot 1 booted, Klipper was ready without `FIRMWARE_RESTART` (that was needed only after stock).

## Phases

0. **Rescue:** eMMC backup and loading over USB (Ingenic mask-ROM). Backup done, USB boot described in `tools/usbboot/README.md`, not verified on the S12 board.
1. **First boot:** kernel and a minimal system in the inactive slot, console, SSH, Wi-Fi, `/usr/data`. **Done** (7 November 2026).
2. **Printing:** Klipper, Moonraker, Mainsail. **Done**, both variants.
3. **Display:** K1 panel driver and the touch application (GuppyScreen). **Missing**, the only stock function Datel OS does not replace yet.
4. **MCUs:** open firmware for all three MCUs and flashing through the Creality serial bootloader. **Done** in the Kalico variant.
5. **Updates:** A/B writes into the non-running slot with `tools/flash-slot2.sh` and a trial boot **work**; an updater on the printer itself (download a release, write, switch without a computer) and an open bootloader with a boot counter (`feat/uboot`) remain.

## Licensing

Our own code, recipes, scripts, documentation and artwork are under the MIT license (file [LICENSE](LICENSE)). The built image contains third-party software under its own licenses; the recipes in the `meta-creality-k1` layer carry a `LICENSE` field and the exact source (`SRC_URI`, `SRCREV`) for every component.

| Component | License | Source |
|---|---|---|
| Linux 6.6 (Ingenic X2000, NebulaOS) | GPL-2.0 | [NebulaOS-KE/NebulaOS-kernel](https://github.com/NebulaOS-KE/NebulaOS-kernel) |
| Kalico (host) and MCU firmware | GPL-3.0 | [pellcorp/kalico](https://github.com/pellcorp/kalico), [pellcorp/k1-kalico-firmware](https://github.com/pellcorp/k1-kalico-firmware) |
| Creality's Klipper (variant `klipper-creality`) | GPL-3.0 | [CrealityOfficial/K1_Series_Klipper](https://github.com/CrealityOfficial/K1_Series_Klipper) |
| Moonraker, Mainsail | GPL-3.0 | upstream |
| uStreamer | GPL-3.0 | [pikvm/ustreamer](https://github.com/pikvm/ustreamer) |
| GuppyScreen | GPL-3.0, MIT, BSD-3 | upstream |
| Wi-Fi chip firmware `brcmfmac43430-sdio.bin` | linux-firmware license (Cypress/Infineon, binary) | linux-firmware |
| NVRAM of the AP6212A Wi-Fi module | no stated license, vendor calibration data (recipe `k1-wifi-nvram`, `LICENSE = "CLOSED"`) | Ingenic SDK / stock K1 firmware |
| Yocto poky, meta-openembedded | MIT and the licenses of the individual packages | upstream |

What is neither in the image nor in a release: the stock bootloader (SPL, U-Boot), the RTOS `zero.bin` and the contents of partition `mmcblk0p9`. They stay on the printer as Creality put them there. Nothing is taken from the pellcorp/creality repository (installer, configuration fragments, `mcu_util.py`), which has no license.
