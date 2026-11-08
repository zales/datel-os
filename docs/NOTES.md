# Engineering log

Findings and measurements by date, kept for reference. The current procedures are in the other documents.

## 5 November 2026: verified without flashing

Learned from the bootloader backup and by reading the live stock system; nothing on the printer changed.

**Bootloader**
- The SPL selects the slot by the text in `mmcblk0p1` (`ota:kernel` or `ota:kernel2`), loads the RTOS of that slot (p3 or p4), the kernel (p5 or p6) and starts it with `root=/dev/mmcblk0p7` or `p8`.
- It has no boot counter and no automatic return to stock; NebulaOS confirms this for the same bootloader on the KE.
- A full U-Boot 2013.07 is in the image with `bootdelay=1`. Whether the SPL runs it on a normal boot is only visible on the J1 console.
- The stock kernel has no kexec.

**Wi-Fi pins (live stock, `hardware/stock-gpio-live.txt`)**

| Signal | Stock | Datel OS |
|---|---|---|
| Power PA01 | output, 0 (on) | regulator active low, always on |
| WL_REG_ON PE02 | output, 1 | `wlan-reg-on-gpios`, the driver sets 1 |
| Host wake PD05 | input with IRQ | interrupt over SDIO, PD05 in the bcmdhd node |
| 32 kHz PE23 | function clk32k | state `enable` when Wi-Fi turns on |
| SDIO msc1 PD08–13 | msc1, 4 bits | `msc1-4bit` |

**Device tree against stock**
- UARTs 1, 2, 3, 5, 7 and 9, I2C2, I2C4, msc0 and msc1 have the same pin groups as stock.
- Fixed to match stock: GPE bank voltage 1.8 V, PWM without the PC01/PC03 mux, I2C3 disabled (it sits on the console pins).
- Touch: the reference printer's display is physically disconnected, so Goodix (0x14) and tlsc6x (0x2e) could not be verified.

**Rescue without J1:** [ballaswag/ingenic-usbboot](https://github.com/ballaswag/ingenic-usbboot) loads its own SPL and U-Boot over USB in mask-ROM mode and can swap p1 or read partitions. Not yet verified on S12; a risk-free read-only test is in [tools/usbboot/README.md](../tools/usbboot/README.md).

## 7 November 2026: first starts

Datel OS started from slot 2 on the first try: kernel 6.6.157-rt79, eMMC, Wi-Fi with the stock MAC, trial mode returning the marker to stock. What failed afterwards and the fixes:

| What failed | Cause | Fix |
|---|---|---|
| SSH refused the key | poky starts sshd with `sshd_config_readonly`; sshd takes the first value of a keyword | the Datel OS block is at the top of both files (`openssh_%.bbappend`) |
| Different IP | systemd-networkd identifies itself with a generated ID, not the MAC | `[DHCPv4] ClientIdentifier=mac` |
| nginx did not run | `listen [::]:80`, the kernel has no IPv6 | line removed |
| Moonraker crashed on import | `streaming-form-data` imports `smart_open` | recipe `python3-smart-open` |
| Klipper restarted every 5 s | Creality's `klipper_mcu` does not know `-I`; `Requires=` stopped Klipper with it | `klipper_mcu -r`, `Wants=` |
| GuppyScreen crashed parsing JSON | it opens the theme for writing, which fails on a read-only root | themes copied to `/usr/data/k1os/guppyscreen/themes`; `ConditionPathExists=/dev/fb0` |

**First print and the FPU.** The first attempt died on a bug in Creality's `virtual_sdcard.py` (variables without defaults when `user_print_refer.json` is missing; fixed in the recipe). The second attempt printed for a few seconds, then the MCU shut down with "Missed scheduling of next digital out event": the host Klipper spent 90 % of its time in the kernel and `/sys/kernel/debug/mips/fpuemustats` showed 1.7 billion emulated FPU instructions. The poky `mips32r2el` tune builds the o32 FP32 ABI with legacy NaN, which the XBurst2 cannot run natively; the stock userspace is `-mfp64 -mnan=2008`. Fix: the own tune `mips32r2el-fp64` and gcc with `--with-fp-32=64 --with-nan=2008`. Side finding: `clock_gettime` costs 12 µs (OST clocksource under a spinlock, no vDSO) against 1.2 µs for a plain syscall.

**Camera.** The Creality camera (UVC 0c45:6366) delivers MJPEG and H.264 straight from the hardware. Upstream uStreamer 6.67 forwards the MJPEG; the NebulaOS fork is not needed.

## 8 November 2026: Kalico in both slots

Slot 1 was overwritten with the Kalico variant as well; stock is gone from the reference printer and its partitions are in the backup. Slot 1 booted and Klipper was ready without `FIRMWARE_RESTART`, which was only needed after a warm restart from stock.

## 8 November 2026: Helix video codec

Stock Creality recorded its timelapse with the X2000's Helix block: its Klipper called `capture 0` at each layer change, `cam_app` pushed the MJPEG frame through the hardware and `ffmpeg -vcodec copy` wrapped the result into MP4. The NebulaOS kernel tree carries the vendor driver in `module_drivers/`, compiled out.

- Enabled with a 32 MiB DMA pool at 0x0e000000; Linux RAM drops from 243 to 216 MiB. `helix-venc` registers as `/dev/video1`; the UVC camera moves to video0 and 2 to 4.
- Rate control: the vendor offers a prebuilt `librc.a_shipped` or a netlink server that neither NebulaOS nor stock ships. Datel OS adds a third Kconfig choice without rate control (fixed QP), later with the QP taken from V4L2 controls so that userspace can regulate the bitrate.
- The first job ever sent to the Helix, a JPEG decode, stopped the whole SoC without a panic. Clocks and memory were in order (`power_helix` is a power gate on `div_ahb0` at 300 MHz; there is no separate VPU clock). The hang did not reproduce on the kernel with patch `0003`, in thousands of frames since, with the hardware watchdog armed (`/dev/watchdog0`). Its cause is unknown, so the timelapse render decodes JPEG in software by default and `HELIX_JPEG=1` enables the hardware decoder.
- Measured: JPEG decode 10 ms and H.264 encode 10 ms a frame at 1280×720, both waiting on the hardware; software JPEG decode 49 ms. 12 frames at QP 28 give 35 KB of H.264 (Main 3.1); the same frames as MJPEG in an MP4 are 2.1 MB. A render through Moonraker takes 2.7 s.
- The V4L2 M2M core runs one job at a time per device: three timelapse renders during a running stream finished at their usual speed while the stream kept its frame rate.

## 8 November 2026: Twitch stream

- Live on the channel: 1280×720 at 8 fps, 2968 kbps download bitrate including the 32 kbit/s audio track, keyframes every 16 frames, 0 skipped frames, 6.8 s latency, codec `avc1.4D401F`.
- On the printer: 26 % of both cores busy with the stream against 13 % without (ffmpeg 4 %, `k1os-stream` 1 %); Mainsail's MJPEG camera kept its 8 fps; 2.3 Mbit/s on the Wi-Fi link at −72 dBm.
- The graph panel costs 0.5 to 0.7 % of one core on top of the text bar's 2 %.
- Controls: Start in the dialog started the service in 1 s, the first title update followed 1 s later; the device-code login completed 37 s after the code was shown; Stop took 1 s.
- Found on the way: Moonraker's service control needs `sudo` in the image even as root, and a static unit that was never started is not listed, so it needs an ordering reference from a started unit. The Twitch player embeds only into HTTPS pages from listed hosts, so the iframe webcam stays black with Mainsail on HTTP.
- An early crash of the streamer when a timelapse render started was its own JPEG parser bug, fixed; it was not a codec conflict.

## Phases

0. **Rescue:** eMMC backup and USB mask-ROM boot. Backup done; USB boot described, not verified on S12.
1. **First boot:** kernel and minimal system in the inactive slot, console, SSH, Wi-Fi, `/usr/data`. Done, 7 November 2026.
2. **Printing:** Klipper, Moonraker, Mainsail. Done, both variants.
3. **Display:** K1 panel driver and GuppyScreen. Missing.
4. **MCUs:** open firmware for all three MCUs and flashing through the Creality serial bootloader. Done in the Kalico variant.
5. **Updates:** A/B writes and trial boot work; an updater on the printer and an open bootloader with a boot counter (`feat/uboot`) remain.
