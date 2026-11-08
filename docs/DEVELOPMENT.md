# Development

## Building

The build runs in Docker with [kas](https://github.com/siemens/kas). The build tree, `sstate-cache` and `downloads` live in the Docker volume `k1yocto-work`, because Yocto needs a case-sensitive file system and the volume keeps a clean build (hours) from happening twice.

```bash
./build.sh                                   # k1-image, variant klipper-creality
KAS_FILE=kas-creality-k1-kalico.yml ./build.sh   # variant kalico
./build.sh virtual/kernel                    # any bitbake target
JOBS=4 ./build.sh                            # bitbake threads and make jobs
```

The log is `build-last.log` in the volume. Images land in `build/tmp/deploy/images/creality-k1/`: `xImage` (kernel), `k1-image-creality-k1.rootfs.squashfs-xz` (system) and `CR4CU220812S11_ota_img_V9.X.Y.Z.img` (the stock updater's package format). `tools/release.sh collect <variant>` copies them out of the volume under their release names; `tools/flash-slot2.sh` installs them, see [INSTALL.md](INSTALL.md).

The kernel is shared by both variants. Yocto's `sstate` makes a variant switch a matter of minutes once both have been built.

## Layer layout

`meta-creality-k1/`:

| Directory | Contents |
|---|---|
| `conf/machine/creality-k1.conf`, `conf/machine/include/` | Machine: MIPS32r2 with the `mips32r2el-fp64` tune, kernel, image types |
| `conf/distro/k1os.conf` | Distro `k1os`, `DISTRO_VERSION` (must match a release tag) |
| `classes/` | The `creality-ota` image type |
| `recipes-kernel/linux/` | NebulaOS kernel recipe, `creality_k1.dts`, config fragment `k1.cfg`, patches |
| `recipes-core/k1os-base/` | Datel OS services: data directory setup, trial boot and slot confirmation, Wi-Fi MAC, camera and printer-name seeding, `k1os-slot` |
| `recipes-core/images/k1-image.bb` | The image |
| `recipes-core/datel-branding/` | Hostname, MOTD, prompt, Mainsail logo |
| `recipes-printer/` | `kalico`, `klipper` (Creality), `k1-mcu-firmware`, `k1os-mcu-update`, `moonraker`, `mainsail`, `guppyscreen`, `ustreamer`, `moonraker-timelapse`, `k1os-helix`, `k1os-stream` |
| `recipes-httpd/nginx/` | Mainsail and camera proxy configuration |
| `recipes-multimedia/ffmpeg/` | ffmpeg trimmed to muxing, MIPS configure fixes |
| `recipes-bsp/k1-wifi-nvram/` | Wi-Fi module calibration file |
| `recipes-devtools/gcc/` | gcc built for FP64 and NaN 2008 |
| `recipes-python/`, `recipes-connectivity/` | Python dependencies of Moonraker, sshd on a read-only root |

Variant selection: `K1OS_KLIPPER` (`klipper-creality` or `kalico`) in the kas file picks the Klipper recipe and the MCU firmware set.

## What it is built on

- **Kernel:** Ingenic X2000 SDK, Linux 6.6.157 with PREEMPT_RT, from [NebulaOS-KE/NebulaOS-kernel](https://github.com/NebulaOS-KE/NebulaOS-kernel), branch `openke`, commit d86790d (the one NebulaOS-firmware 1.0 pins). NebulaOS runs an open firmware for the Ender-3 V3 KE on it, which has the same chip and mostly the same wiring. The configuration differs from NebulaOS only where the K1 needs it: the K1 device tree, Goodix touch, Bluetooth, XZ squashfs, brcmfmac as a module with its firmware in the rootfs, and the Helix video codec.
- **Device tree:** `creality_k1.dts` includes the KE board file and changes what differs on the K1: console, MCU UARTs, touch, display, Wi-Fi and Bluetooth pins, the codec's DMA pool. Every value names the stock file it comes from (`hardware/`).
- **System:** Yocto scarthgap (poky, meta-oe, meta-python, meta-networking, meta-webserver, meta-arm for the MCU toolchain), systemd, read-only root.
- **Update package:** the image type `creality-ota` produces an `.img` that the stock updater and a future own updater install. It holds the kernel and the system squashfs and goes into the inactive set of partitions.

## Design decisions worth knowing

**Everything from source, no blobs.** The only binaries in the image are the Wi-Fi chip firmware and its calibration data. The kernel's resume-from-suspend stub is rebuilt from its source in the tree; the vendor's rate-control library for the video encoder is replaced by a fixed-QP mode with the rate control in userspace.

**FPU ABI.** The XBurst2 FPU has 64-bit registers and only the NaN 2008 encoding. The poky tune `mips32r2el` builds the o32 FP32 ABI with legacy NaN, which the kernel then emulates instruction by instruction; the first print died of it. Datel OS therefore has its own tune `mips32r2el-fp64` and gcc with `--with-fp-32=64 --with-nan=2008`, the same ABI as the stock userspace. Changing it means rebuilding the whole userspace.

**Trial boot.** The stock SPL selects the slot by the text in `mmcblk0p1` and has no boot counter. `k1os-trial-boot.service` points the marker at the other slot before file systems are mounted; `k1os-slot-confirm.service` points it back once `/usr/data` is up and `/usr/data/k1os/boot-keep` exists. See `recipes-core/k1os-base/files/k1os-slot`.

**Helix video codec.** The X2000 has a hardware H.264/JPEG encoder and JPEG decoder (Helix, `/dev/video1`, V4L2 memory-to-memory) and an H.264 decoder (Felix, not built). The vendor driver in `module_drivers/` is enabled with `CONFIG_VIDEO_INGENIC_VCODEC` and `CONFIG_INGENIC_HELIX` and needs a 32 MiB `shared-dma-pool` (`creality_k1.dts`). Three patches in `recipes-kernel/linux/files/`: `0001` adds the rate-control choice `RC_NONE` (the vendor offers a prebuilt `librc.a` or a netlink server nobody has), `0002` fixes a `MAX`/`MIN` redefinition under `-Werror`, `0003` builds the per-frame slice header and descriptor under `RC_NONE` and takes the QP from the V4L2 controls `V4L2_CID_MPEG_VIDEO_H264_I_FRAME_QP` and `P_FRAME_QP`. Userspace: `k1os-helix-enc` (timelapse) and `k1os-stream` (Twitch) in `recipes-printer/`. Driver quirks: `S_FMT` on the capture queue resets the encoder parameters, so controls are set after it; the control framework skips unchanged values, so write them after every `S_FMT`; the JPEG decoder returns the picture size in `buf->reserved`.

**Camera node sharing.** A UVC node streams to one process. uStreamer serves Mainsail and publishes every frame into the shared-memory sink `k1os::jpeg`; the Twitch streamer reads from there.

**Read-only root.** Moonraker, Klipper and GuppyScreen expect writable trees. Moonraker's database, Klipper's configuration, timelapse files and all settings live under `/usr/data/k1os` (partition `mmcblk0p10`, shared by both slots); `k1os-datadir-setup` creates them on the first start and copies defaults once. `/usr/data/k1os/printer_data/config` holds `printer.cfg` and `moonraker.conf`.

**Moonraker as root with `systemd_cli`.** Datel OS has no PolKit. Moonraker's service control runs `sudo systemctl`, so `sudo` is in the image; a static unit that was never started is not offered by Moonraker, hence the ordering reference from `k1os-twitch-autostart.service`.

## Pitfalls known up front

- The bootloader passes `init=/linuxrc`; the image links it to `/sbin/init`.
- The bootloader selects the display type with `lcm_id=<n>` on the command line. The reference printer has `lcm_id=3` (ST7701 "tjc"); five more panel variants exist.
- Partition `mmcblk0p9` is the writable overlay of stock and holds the user's stock modifications. Datel OS never mounts it.
- The RTOS of the third core (`zero.bin`, partitions p3/p4) is closed and shows the boot logo. `tools/rtos-splash.py` can replace the logo JPEGs inside a copy of the partition with the Datel OS logo; write the result only to the Datel OS slot and keep the original.
- The Wi-Fi firmware is `cyfmac43430` from linux-firmware; the NVRAM is the AP6212A file from the Ingenic SDK and stock (`ccode=CN`), installed as `brcmfmac43430-sdio.creality,k1.txt`. The regulatory database is in the image, so the kernel uses the country from `wpa_supplicant.conf`.
- The MAC address is read from the `sn_mac` partition before wpa_supplicant starts (`wifi-mac`), falling back to `/usr/data/macaddr.txt`, so the router gives the printer the same address as stock.
- `clock_gettime` costs 12 µs on this kernel (OST clocksource under a spinlock, no vDSO).
- The RAM for Linux is 216 MiB with the codec's DMA pool. Input shaper fitting on the printer does not fit in it; `tools/shaper-fit.sh` does it on the computer.

## Branches

- `main`: both variants, what the releases are built from.
- `feat/uboot`: an open U-Boot with a boot counter, not verified on the printer.

Releases are tags `vX.Y.Z` built by a self-hosted runner, see [RELEASE.md](RELEASE.md). The engineering log with dated findings is [NOTES.md](NOTES.md).
