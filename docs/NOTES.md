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

Slot 1 was overwritten with Datel OS as well; stock is gone from the reference printer and its partitions are in the backup. Slot 1 booted and Klipper was ready without `FIRMWARE_RESTART`, which was only needed after a warm restart from stock.

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

## 9 November 2026: Mainsail stalls on connect

- Every time Mainsail connected, Moonraker logged `EVENT LOOP BLOCKED` for 6-9 s and the UI looked dead, worst during the start of a print when Klipper keeps one of the two cores busy. Cause: `server.files.list` and `server.files.get_directory` build the listing on the event loop thread (`os.walk`, a `stat()` per file, the in-memory metadata cache); with 273 files in `gcodes` since December 2023 that took 2.0 s and 2.7 s on the X2000 (0.3 s and 0.4 s with 34 files). Moonraker v0.11.0 upstream.
- Fix in the Moonraker recipe: `0001-file_manager-build-file-listings-off-the-event-loop.patch` runs both listings through `event_loop.run_in_thread`, the way the move and copy handlers already do. Nothing else in the handlers touches state that needs the loop thread.
- The old files were moved to `/usr/data/gcode-archive` on the printer (outside Moonraker's roots).
- Unrelated, same day: the bed `max_temp` of the stock S12 config is 115 and the ASA profile asked for exactly 115; a 0.1 degree overshoot shut the MCU down. The printer now runs with 120 (stock S11 ships 120, S10 125, same heater and thermistor).

## 9 November 2026: boot time

- Measured on v0.3.1 from the journal (`systemd-analyze` is not in the image; `systemctl show` gives the same stamps). Seconds from the kernel start, the stock bootloader before it is not measured (J1 console): root mounted 1.3, systemd 2.6, `basic.target` 11.6, `k1os-wifi` 12.5 (wlan0 existed from 9.3), Wi-Fi associated 16.2 and DHCP 16.9, Klipper start 13.8 with "Start printer" at 25.8, Moonraker start 17.3 with the HTTP server up at 45.6, Klippy ready in Mainsail at 47.
- Two findings. `sshd_check_keys` generated an RSA host key into `/var/run/ssh` on every boot, 42 s of one core from 12 s to 54 s, right under the two Python start-ups: poky's `sshd_config_readonly` ends with `HostKey /var/run/ssh/...` lines that the Datel OS block in front of it does not override (HostKey is cumulative). Moonraker blocks its event loop for 7 to 9 s between the component post-inits and `start_server`, since 7 November afternoon (restarts that morning took 9 s end to end, since then 19 to 21 s); the stall is not in the `component_init` of `timelapse` or `k1os_stream`, both are non-blocking, and still needs a stack dump during a restart to name it.
- Changes: the bbappend drops the `/var/run/ssh` HostKey lines and `k1os-datadir.service` is ordered before `sshdgenkeys.service`, so sshd finds the persistent keys and generates nothing. `k1os-datadir.service` and `k1os-wifi.service` run with `DefaultDependencies=no` right after `usr-data.mount` and the wlan0 device instead of after `basic.target`. `moonraker.service` no longer waits for `network-online.target` (6.6 s of `systemd-networkd-wait-online`); it listens on 0.0.0.0 and its own start-up is longer than the Wi-Fi association.
- Result on the first boot with the changes (10 November, a warm `reboot` into slot 2): `sshdgenkeys` took 1.3 s and `/var/run/ssh` stays empty; Moonraker went from service start to a listening HTTP server in 20.4 s instead of 28.3 s and logged no `EVENT LOOP BLOCKED` at start-up (post-inits to `start_server` 3.2 s instead of 9.2 s; whether the freed core or the file-listing patch in the same build did that is not separated); Moonraker starts 2.3 s after `basic.target` instead of 5.7 s and listens 22.7 s after it instead of 34.0 s. No failed units, no ordering cycle, Klipper ready.
- The absolute times of that boot do not compare with the cold boot above: after a warm reboot the MCUs run their application, `k1os-mcu-update` waits for the bootloaders from 5.1 s to 30.5 s and, being `Before=sysinit.target`, holds `basic.target` until 30.9 s (11.6 s after power-on). Moonraker listened at 53.6 s, Klippy was ready at 61.4 s. The earlier Wi-Fi start cannot show there either, `k1os-datadir.service` is ordered after the update. A cold-boot measurement of the new image is still missing.
- Warm reboots fixed the same night: `k1os-mcu-update` passes `--quick` to `k1os-mcu-flash` when the kernel log has no `ingenic_rtc: rtc power on reset` line (printed only when the RTC scratch register lost its value, that is after a power-on), and the probe then runs two rounds with a 0.5 s reply timeout instead of 20 s with 2 s. A bootloader that is there after all still answers the first round. Tried from `/tmp` with Klipper stopped: 3.5 s for the three ports against 20.4 s for one. Next warm reboot (slot 1): the update ran from 5.1 s to 11.8 s instead of 30.5 s, `basic.target` at 12.2 s, Moonraker listening at 33.7 s instead of 53.6 s, Klippy ready at 42.1 s instead of 61.4 s; from the `reboot` command to an answer on port 7125 it took 45 s instead of 71 s. Wi-Fi came up at the old time (DHCP at 16.8 s): `k1os-datadir.service` still follows the update, which now ends about when `basic.target` would be reached anyway.
- What is left is Python: Moonraker needs 19 s from start to listening (7 s of it imports) and Klipper 12.5 s to "Start printer" plus 15.5 s until it is ready.

## 10 November 2026: a hang in the middle of a print

- The printer stopped answering 50 minutes into a print, on a build with go2rtc and the Twitch stream running; klippy.log and moonraker.log simply end. Nothing told why: the journal was in RAM and the copy on disk was overwritten 30 s into the next boot. The cause of that hang is not proven.
- What was then seen live, twice the same evening: with Wi-Fi at -85 to -89 dBm go2rtc grew from 30 to 62 MB in five minutes and available memory fell from 70 to 30 MB. go2rtc queues up to 4096 packets for a WebRTC viewer; from the Helix encoder a packet is a whole frame of 40 kB. A reader of `stream.mp4` that stalls (the Twitch path) only makes it drop frames. Reproduced off the printer with the network limited by `tc tbf` (not netem, which does not make UDP sends block): 35 -> 64 MB in three minutes; with a 2 MiB limit on the queue it stops at 36 MB. go2rtc is built from source for that patch.
- Why short memory froze the printer instead of killing something: no swap, so the kernel dropped program code and read it back through xz from the squashfs with a single decompressor, and that still counted as progress. klippy, go2rtc and Moonraker had the same OOM score within 3 %. Now: zram swap, the multi-gen LRU with `min_ttl_ms=1000`, `OOMScoreAdjust` on the units. A process taking 8 MB a second is killed after 19 s and the printer answers every second in between.
- The Helix codec was the other suspect (its first job once stopped the SoC, 8 November). Ten boots in which a hardware JPEG decode was the first job of the codec all passed, 15 to 35 ms.
- uStreamer: a snapshot request hung when nobody else was watching, 1 in 40 on an idle printer and 25 in 150 with both cores busy. The JPEG thread exposed the frame (waking the HTTP thread) before it counted the snapshot as processed. With the order swapped: 0 in 300.
- `iw` reports `rx bitrate 1.0 MBit/s` and 69 000 failed transmissions on the bad evening; a 75 MB upload to the printer took 19 minutes until go2rtc was stopped, then under one. With the regulatory database in the kernel the domain is the country from `wpa_supplicant.conf` instead of the world default.

## Phases

0. **Rescue:** eMMC backup and USB mask-ROM boot. Backup done; USB boot described, not verified on S12.
1. **First boot:** kernel and minimal system in the inactive slot, console, SSH, Wi-Fi, `/usr/data`. Done, 7 November 2026.
2. **Printing:** Klipper, Moonraker, Mainsail. Done. Creality's Klipper served as the fallback during bring-up and was dropped on 8 November 2026; Kalico is the only system.
3. **Display:** K1 panel driver and GuppyScreen. Missing.
4. **MCUs:** open firmware for all three MCUs and flashing through the Creality serial bootloader. Done.
5. **Updates:** A/B writes and trial boot work; an updater on the printer and an open bootloader with a boot counter (`feat/uboot`) remain.
