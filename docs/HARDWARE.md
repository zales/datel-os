# Hardware Creality K1 (CR4CU220812S11, firmware 1.3.3.46)

Zjištěno 5. 11. 2026 na tiskárně 192.168.1.104 přes SSH. Zdroje jsou v `hardware/`: živý device tree (`k1-stock.dts`), parametry stock modulů (`stock-module-params/`) a příkazová řádka jádra.

## Čip a paměť

| Položka | Hodnota |
|---|---|
| SoC | Ingenic X2000: 2× XBurst2 (MIPS32r2 + MSA) a jádro XBurst0 pro RTOS |
| RAM | 256 MiB, Linux vidí 214 MiB |
| Úložiště | eMMC 8 GB na msc0, 8bit, HS200 |
| Stock jádro | 4.4.94 od Ingenicu, Buildroot 2020.02.1 |

## Oddíly eMMC

| Oddíl | Velikost | Obsah |
|---|---|---|
| mmcblk0p1 | 1 MiB | Značka aktivního slotu, teď `ota:kernel` |
| mmcblk0p2 | 1 MiB | Údaje o zařízení: sériové číslo, model CR-K1, deska CR4CU220812S12 |
| mmcblk0p3 / p4 | 4 MiB | RTOS, slot A / B |
| mmcblk0p5 / p6 | 8 MiB | Jádro `xImage`, slot A / B |
| mmcblk0p7 / p8 | 300 MiB | Systém, squashfs, slot A / B |
| mmcblk0p9 | 100 MiB | Zapisovatelná vrstva stocku, ext4 |
| mmcblk0p10 | 6,6 GiB | `/usr/data`, ext4, sdílené |

## Periferie

| Periferie | Zapojení | Zdroj |
|---|---|---|
| Konzole | ttyS2 (uart2, PD30/31), 115200 | cmdline |
| MCU hlavní deska, GD32F303RET6 | ttyS7 (uart7, PA08/09) | printer.cfg, DT |
| SWD k hlavnímu MCU | SWDIO PA10, SWCLK PA06, NRST PA07 | DT `creality,swd` |
| MCU hlavy, GD32F303CBT6 | ttyS1 (uart1, PC23/24) | printer.cfg, DT |
| MCU senzoru, GD32E230F8P6 | ttyS9 (uart9, PB30/31) | printer.cfg, DT |
| UART5 | PA04/05, zapnutý, účel neznámý | DT |
| Displej | ST7701 RGB 480×800, inicializace 9bit SPI: SCK PC27, SDA PC28, CS PA02, SDO PB16, reset PB29, napájení PC21 | lcd_st7701_9bit_spi_tjc_480_800.sh |
| Varianta panelu | Bootloader předává `lcm_id`. Tady 3 = tjc, dále tjc_lc, dc, pj, pj_lc, gc9503cv_ue | cmdline, moduly |
| Podsvícení | PWM0 na PC00, zapnutí PC22, 50 kHz | pwm_backlight.sh |
| Dotyk | Goodix GT9xx na i2c4 (PC25/26) adresa 0x14, reset PA00, IRQ PA03. Některé kusy mají tlsc6x na 0x2e | gt9xx_touch.sh, tlsc6x.sh |
| Wi-Fi | Modul AP6212A, CYW43438 rev 1 (SDIO 02d0:a9a6) na msc1, 4bit. Napájení PA01 aktivní v nule, WL_REG_ON PE02, host wake PD05. Stock nahrává fw_bcm43438a1.bin 7.45.96.76 a nvram_ap6212a.txt. MAC je v oddílu `sn_mac` (sektor 1, druhé pole za `;`) | soc_msc.sh, cywdhd.sh, get_sn_mac.sh |
| Bluetooth | Tentýž čip přes UART3 (PD00–03), H5. BT_REG_ON PE00, wake PE03/PE01 | cywdhd.sh, DT |
| Kamera | USB UVC „CREALITY CAM“, Sonix 0c45:6366, přes hub 05e3:0608 | sysfs |
| Zvuk | Interní kodek X2000 (icodec) | lsmod |
| LED | sys-led PA13, aktivní v nule | DT |
| I2C2 | PB22/23, 400 kHz | soc_i2c.sh |

## Bootloader

- Načte `xImage` ze slotu podle značky v mmcblk0p1 a předá jádru `console=ttyS2,115200n8 mem=256M@0x0 lcm_id=3 init=/linuxrc root=/dev/mmcblk0p7 rootwait rootfstype=squashfs ro`.
- Zdroj U-Boot pro X2000 je v Ingenic SDK, ale výměna bootloaderu je nejriskantnější krok. Datel OS ho zatím nemění.
