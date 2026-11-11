# Creality K1 hardware (CR4CU220812S11, firmware 1.3.3.46)

Found on 5 November 2026 on the printer at 192.168.1.104 over SSH. The sources are in `hardware/`: the live device tree (`k1-stock.dts`), the parameters of the stock modules (`stock-module-params/`) and the kernel command line.

## Chip and memory

| Item | Value |
|---|---|
| SoC | Ingenic X2000: 2× XBurst2 (MIPS32r2 + MSA) and an XBurst0 core for the RTOS. The boot loader sets 1200 MHz (APLL; the buses run from the 1500 MHz MPLL); Datel OS lowers the CPU to 816 MHz, see [DIAGNOSTICS.md](DIAGNOSTICS.md#cpu-clock-and-floating-point). The datasheet describes XBurst2 as a core with two hardware threads; Linux sees two CPUs |
| RAM | 256 MiB, Linux sees 214 MiB |
| Storage | 8 GB eMMC on msc0, 8-bit, HS200 |
| Stock kernel | 4.4.94 from Ingenic, Buildroot 2020.02.1 |

## eMMC partitions

| Partition | Size | Contents |
|---|---|---|
| mmcblk0p1 | 1 MiB | Active slot marker, currently `ota:kernel` |
| mmcblk0p2 | 1 MiB | Device data: serial number, model CR-K1, board CR4CU220812S12 |
| mmcblk0p3 / p4 | 4 MiB | RTOS, slot A / B |
| mmcblk0p5 / p6 | 8 MiB | Kernel `xImage`, slot A / B |
| mmcblk0p7 / p8 | 300 MiB | System, squashfs, slot A / B |
| mmcblk0p9 | 100 MiB | Writable overlay of stock, ext4 |
| mmcblk0p10 | 6.6 GiB | `/usr/data`, ext4, shared |

## Peripherals

| Peripheral | Wiring | Source |
|---|---|---|
| Console | ttyS2 (uart2, PD30/31), 115200 | cmdline |
| Main board MCU, GD32F303RET6 | ttyS7 (uart7, PA08/09) | printer.cfg, DT |
| SWD to the main MCU | SWDIO PA10, SWCLK PA06, NRST PA07 | DT `creality,swd` |
| Toolhead MCU, GD32F303CBT6 | ttyS1 (uart1, PC23/24) | printer.cfg, DT |
| Sensor MCU, GD32E230F8P6 | ttyS9 (uart9, PB30/31) | printer.cfg, DT |
| UART5 | PA04/05, enabled, purpose unknown | DT |
| Display | ST7701 RGB 480×800, initialisation over 9-bit SPI: SCK PC27, SDA PC28, CS PA02, SDO PB16, reset PB29, power PC21 | lcd_st7701_9bit_spi_tjc_480_800.sh |
| Panel variant | The bootloader passes `lcm_id`. Here 3 = tjc; also tjc_lc, dc, pj, pj_lc, gc9503cv_ue | cmdline, modules |
| Backlight | PWM0 on PC00, enable PC22, 50 kHz | pwm_backlight.sh |
| Touch | Goodix GT9xx on i2c4 (PC25/26) address 0x14, reset PA00, IRQ PA03. Some units have a tlsc6x at 0x2e | gt9xx_touch.sh, tlsc6x.sh |
| Wi-Fi | AP6212A module, CYW43438 rev 1 (SDIO 02d0:a9a6) on msc1, 4-bit. Power PA01 active low, WL_REG_ON PE02, host wake PD05. Stock loads fw_bcm43438a1.bin 7.45.96.76 and nvram_ap6212a.txt. The MAC is in the `sn_mac` partition (sector 1, second field after `;`) | soc_msc.sh, cywdhd.sh, get_sn_mac.sh |
| Bluetooth | The same chip over UART3 (PD00–03), H5. BT_REG_ON PE00, wake PE03/PE01 | cywdhd.sh, DT |
| Camera | USB UVC "CREALITY CAM", Sonix 0c45:6366, behind hub 05e3:0608 | sysfs |
| Audio | Internal X2000 codec (icodec) | lsmod |
| LED | sys-led PA13, active low | DT |
| I2C2 | PB22/23, 400 kHz | soc_i2c.sh |

## Bootloader

- Loads the `xImage` from the slot named by the marker in mmcblk0p1 and passes the kernel `console=ttyS2,115200n8 mem=256M@0x0 lcm_id=3 init=/linuxrc root=/dev/mmcblk0p7 rootwait rootfstype=squashfs ro`.
- The U-Boot source for the X2000 is in the Ingenic SDK, but replacing the bootloader is the riskiest step. Datel OS does not change it yet.
