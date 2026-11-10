# Kalico and the MCU firmware

Datel OS prints with Kalico and loads open firmware into all three MCUs; Creality's Klipper and the stock MCU firmware are not part of the image.

## Components

| Part | Source | Notes |
|---|---|---|
| Host | [pellcorp/kalico](https://github.com/pellcorp/kalico), branch `aug2026` | Kalico with the K1 additions: strain gauge probe (`load_cell_probe`, `hx711s`), MCU bootloader entry |
| MCU firmware | [zales/k1-kalico-firmware](https://github.com/zales/k1-kalico-firmware), branch `fix/gd32-port-cleanup`: pellcorp's `aug2026` plus five commits | Creality's GD32 port, built with the `gcc-arm-none-eabi` toolchain from meta-arm, with the header the Creality bootloader expects. The fork puts the scheduler back to upstream (a timer that is already late shuts the MCU down; Creality's port moved it 2 µs ahead and carried on), drops the port's debug counters and links with GCC 13 |
| Flashing | `k1os-mcu-update` (own) | Talks to the Creality serial bootloader on all three ports at once right after boot, writes a firmware only when the version differs, then starts the application |
| Configuration | `k1os-kalico-config` (own) | Converts the stock `printer.cfg` once on the first start, backup next to it as `config.creality-<date>` |

MCUs: mainboard GD32F303xE (`/dev/ttyS7`), nozzle GD32F303xB (`/dev/ttyS1`), bed leveling GD32E230x8 (`/dev/ttyS9`), all at 230400 baud.

Firmware updates happen only on a cold start: the bootloader waits about 15 s after power-on, and a running Klipper cannot be sent into it. After a plain reboot the MCUs keep the firmware they have and `k1os-mcu-update` logs them as skipped; it knows a reboot by the missing `rtc power on reset` line in the kernel log (the RTC loses its state only with the board's power) and then probes each port for about 2 s instead of 20 s, so the boot does not wait for bootloaders that cannot answer. The bed MCU keeps streaming sensor frames after the host is gone, so its port is never quiet; the probe takes only a plausible version string as a bootloader answer.

## What the configuration conversion does

- Removes `prtouch_v2`, `bl24c16f`, `custom_macro` and `fan_feedback`.
- Switches the Z endstop to `probe:z_virtual_endstop`.
- Includes `k1os_kalico.cfg` with the probe, the mesh, replacements for Creality's commands (`CX_PRINT_LEVELING_CALIBRATION`, `CX_PRINT_DRAW_ONE_LINE`, `PRTOUCH_READY`, …), the timelapse macros and the Twitch macros.
- Seeds the `SAVE_CONFIG` block with values measured on one K1 unless stock already has them: `[load_cell_probe]` counts_per_gram 116.7 and tare, `[input_shaper]` X ei 42.2 Hz, Y mzv 53.2 Hz. The printer homes and meshes right after flashing; your own calibration is recommended.

## Calibration

1. **Load cell:** in the Mainsail console `LOAD_CELL_DIAGNOSTIC`, then `LOAD_CELL_CALIBRATE` with a weight of about 6 kg: `TARE`, `CALIBRATE GRAMS=6000`, `ACCEPT`, `SAVE_CONFIG`. The values live in the `#*#` block of `printer.cfg`, not in `k1os_kalico.cfg`.
2. **Probe and mesh:** `G28`, `PROBE_ACCURACY`, set the probe `z_offset`, `BED_MESH_CALIBRATE`. The probe runs at 3 mm/s, the same as the Z homing speed, so homing and the mesh share one reference.
3. **Input shaper:** `SHAPER_CALIBRATE` does not work on the printer: the fit needs more RAM than the K1 has, the process is killed and Klipper waits for it forever (`systemctl restart klipper` recovers). Record instead and fit on the computer:

```
G28
TEST_RESONANCES AXIS=X OUTPUT=raw_data
TEST_RESONANCES AXIS=Y OUTPUT=raw_data
```

```bash
PRINTER=root@<ip> tools/shaper-fit.sh
```

Write the result into the `SAVE_CONFIG` block.

## Fans

| Name | Function |
|---|---|
| `fan0` | Part cooling (nozzle board) |
| `fan1` | Chamber fan with the filter (rear) |
| `fan2` | Auxiliary side fan |

`M106 P<n>` maps 1:1, so OrcaSlicer's auxiliary fan `P2` is right; the exhaust `P3` is routed to `fan1`. The `output_pin` sliders in Mainsail send raw PWM: `fan1` spins from about 50/255, `fan2` from about 180/255.

## Known behaviour

- After a warm restart from stock into Datel OS the main MCU stays in shutdown and Kalico reports "Can not update MCU 'mcu' config as it is shutdown". One `FIRMWARE_RESTART` fixes it. It does not happen on a normal start or between two Datel OS slots.
- Going back to stock: stock reflashes its own MCU firmware on the next cold start.
- Licensing: Kalico and the firmware are GPL-3.0. The pellcorp/creality repository (installer, configuration fragments, `mcu_util.py`) has no license, so nothing is taken from it; the flasher and the configuration conversion are Datel OS's own.
