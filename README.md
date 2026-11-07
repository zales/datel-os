<img src="docs/logo.svg" width="96" align="right" alt="Datel OS">

# Datel OS: otevřený firmware pro Creality K1 na Yoctu

**Datel** (strakapoud/datel) – pták, který klepe zobákem do dřeva. Přesně to dělá tahle tiskárna: tryska poklepe na podložku a tenzometry pod ní řeknou, kde je nula. Jméno je české, krátké a dá se vyslovit; hostname je `datel`, značka v terminálu i v Mainsailu je stejný pták. Interní jména souborů a cest (`k1os-*`, `/usr/data/k1os`) zůstávají – jsou to identifikátory, ne značka.

Cíl je vlastní systém postavený celý ze zdrojových kódů: jádro, systém, Klipper, Moonraker, webové rozhraní, aplikace na displej i firmware všech tří MCU. Stock bootloader zůstává, takže se dá kdykoli vrátit ke stock firmwaru ve druhé sadě oddílů.

## Stav

| Část | Stav |
|---|---|
| Mapa hardwaru K1 | Hotová, viz [docs/HARDWARE.md](docs/HARDWARE.md) |
| Formát aktualizací Creality | Rozluštěný a ověřený na oficiálním 1.3.3.46 |
| Vrstva `meta-creality-k1` (scarthgap) | Bitbake ji načte bez chyb |
| Jádro 6.6.157-rt pro K1 | Postavené: `xImage` 4,8 MB ve stejném formátu a na stejné adrese jako stock (uImage, 0x80F00000) |
| Device tree desky K1 | Přeloží se a je zabudovaný v jádře. UARTy odpovídají stocku. Na tiskárně netestovaný |
| Ovladač displeje K1 | Chybí |
| Klipper, Moonraker, Mainsail, GuppyScreen | V obrazu: Klipper od Creality, Moonraker v0.8.0-247, Mainsail 2.9.0 na nginx, GuppyScreen. Klipper a Moonraker ověřené pod Pythonem 3.12, na tiskárně netestované |
| Celý obraz | `out/CR4CU220812S11_ota_img_V9.0.1.0.img`, 62 MB, systém 57 MB (216 MB rozbalený) |
| Firmware MCU | Chybí, fáze 4 |

## Na čem to stojí

- **Jádro:** Ingenic X2000 SDK, Linux 6.6.157 s PREEMPT_RT, z repozitáře [NebulaOS-KE/NebulaOS-kernel](https://github.com/NebulaOS-KE/NebulaOS-kernel), větev `openke`. NebulaOS na něm provozuje otevřený firmware pro Ender-3 V3 KE, který má stejný čip a z velké části stejné zapojení. Commit d86790d je stejný, jaký pinuje NebulaOS-firmware 1.0. Obsahuje všech 8 jejich oprav, které dřív přidávaly skripty při sestavení: PREEMPT_RT, in-band IRQ a vysokou rychlost SDIO pro Wi-Fi, VSYNC u displeje, opravu pinctrl, řízení podsvícení, čtení stavu PWM, ovladač dotyku NS2009 a vypnutý roaming v brcmfmac. Od 3. 10. 2026 jsou to commity v jádře (NebulaOS-firmware b93415a). Konfigurace se od NebulaOS liší jen v tom, co potřebuje K1: device tree K1, Goodix, Bluetooth, squashfs XZ a brcmfmac jako modul s firmwarem v rootfs.
- **Desková podpora K1:** device tree `creality_k1.dts` přebírá desku KE a mění, v čem se K1 liší: konzoli, UARTy pro MCU, dotyk, displej, piny Wi-Fi a Bluetooth. Každá hodnota odkazuje na stock soubor, ze kterého pochází.
- **Systém:** Yocto scarthgap (poky, meta-oe, meta-python, meta-networking), systemd, kořen jen pro čtení.
- **Balík aktualizace:** typ obrazu `creality-ota` vyrobí `.img`, který nainstaluje stock aktualizace i vlastní updater. Obsahuje jádro a squashfs systému a zapisuje se do neaktivní sady oddílů.

## Build

Nejjednodušeji `./build.sh`, výsledek je v Docker volume a v logu `build-last.log` tamtéž. Vydání (tag `vX.Y.Z` → GitHub Release s obrazy) popisuje [docs/RELEASE.md](docs/RELEASE.md).

Potřebuje Docker. Build musí běžet na souborovém systému, který rozlišuje velikost písmen, proto pracovní adresář žije v Docker volume.

```bash
docker volume create k1yocto-work
docker run --rm -u root -v k1yocto-work:/work -v "$PWD":/src:ro --entrypoint bash ghcr.io/siemens/kas/kas:4.7 -c \
  'mkdir -p /work/k1-yocto && cp -r /src/meta-creality-k1 /src/kas-creality-k1.yml /work/k1-yocto/ && chown -R builder:builder /work &&
   su builder -c "cd /work/k1-yocto && KAS_WORK_DIR=/work/k1-yocto kas build kas-creality-k1.yml"'
```

## Úskalí, která jsou známá dopředu

- **Bootloader předává `init=/linuxrc`.** Obraz proto vytváří `/linuxrc` jako odkaz na `/sbin/init`.
- **Typ displeje vybírá bootloader** parametrem `lcm_id`. Tahle tiskárna má `lcm_id=3`, panel ST7701 „tjc“. Existuje ještě dalších pět variant panelu.
- **Oddíl `mmcblk0p9` je zapisovatelná vrstva stocku** a jsou v ní tvoje úpravy. Datel OS ho nesmí připojit. Data ukládá jen do `/usr/data/k1os`.
- **RTOS pro třetí jádro (`zero.bin`) je uzavřený.** Balík Datel OS ho neobsahuje a slot si nechá ten stávající. Je to FreeRTOS s ovladačem panelu ST7701 a JPEG dekodérem – jeho jediná viditelná práce je logo na displeji, než naběhne Linux. Obrázky (jeden pro každou orientaci panelu) v něm leží jako JPEG se symbolovou tabulkou a SPL obraz nekontroluje, takže `tools/rtos-splash.py` je umí nahradit logem Datel OS na místě (stejná délka, dopad nulami): `dd if=/dev/mmcblk0p4 bs=1M count=4 of=p4.bin` → `tools/rtos-splash.py p4.bin p4-datel.bin` → zápis zpět jen do p4 (slot Datel OS), originál si nech na návrat.
- **Firmware Wi-Fi čipu je binární** (cyfmac43430 z linux-firmware). Jinak to nejde. NVRAM (kalibrace rádia) je soubor modulu AP6212A ze stocku, stejný jako v Ingenic SDK, jen s `ccode=CN`. Recept `k1-wifi-nvram` ho instaluje jako `brcmfmac43430-sdio.creality,k1.txt` a obecné jméno na něj odkazuje.
- **Regulační databáze Wi-Fi** (`wireless-regdb-static`) je v obrazu, takže jádro použije zemi z `wpa_supplicant.conf`.
- **Wi-Fi přebírá nastavení ze stocku.** Při prvním startu se `/usr/data/wpa_supplicant.conf` zkopíruje do `/usr/data/k1os/`. Další změny se mezi systémy nepřenáší.
- **MAC adresa je stejná jako na stocku.** Skript `wifi-mac` ji před spuštěním wpa_supplicant čte z oddílu `sn_mac`, potom z `/usr/data/macaddr.txt`. Router tak tiskárně dá stejnou IP.
- **Jádro neobsahuje žádnou cizí binárku.** Jediná, kód pro probuzení ze spánku, se překládá ze zdroje ve stromu. Překlad novějším GCC se od dodané binárky liší, ale velikost sedí.

## Co je ověřené bez flashování (5. 11. 2026)

Zjištěno ze zálohy bootloaderu a čtením ze živého stocku, na tiskárně se nic nezměnilo.

**Bootloader**
- Slot vybírá už SPL podle textu v p1 (`ota:kernel` nebo `ota:kernel2`). Pak načte RTOS daného slotu (p3 nebo p4), jádro (p5 nebo p6) a spustí ho s `root=/dev/mmcblk0p7` nebo `p8`.
- Žádné počítadlo pokusů ani automatický návrat na stock nemá. NebulaOS to pro stejný bootloader na KE potvrzuje. Když nové jádro zamrzne, zamrzne při každém startu.
- Plný U-Boot 2013.07 v obrazu je, s `bootdelay=1` a výzvou „Hit any key to stop autoboot“. Jestli ho SPL při běžném startu vůbec spouští, ukáže až konzole na J1.
- RTOS ve slotu 2 (p4) má platnou hlavičku. Balík Datel OS ho nepřepisuje.
- Stock jádro nemá kexec, takže nové jádro nejde vyzkoušet bez restartu.

**Wi-Fi piny (živý stock, `hardware/stock-gpio-live.txt`)**

| Signál | Stock | Datel OS |
|---|---|---|
| Napájení PA01 | výstup, 0 (zapnuto) | regulátor aktivní v nule, vždy zapnutý |
| WL_REG_ON PE02 | výstup, 1 | `wlan-reg-on-gpios`, ovladač nastaví 1 |
| Host wake PD05 | vstup s IRQ | přerušení přes SDIO, PD05 v uzlu bcmdhd |
| 32 kHz PE23 | funkce clk32k | stav `enable` při zapnutí Wi-Fi (late_initcall z NebulaOS) |
| SDIO msc1 PD08–13 | msc1, 4 bity | `msc1-4bit` |

**Device tree proti stocku**
- UARTy 1, 2, 3, 5, 7 a 9 mají stejné skupiny pinů jako stock. I2C2, I2C4, msc0 a msc1 také.
- Opraveno podle stocku: napětí banky GPE 1,8 V (stock má v registru 0x100000E0 hodnotu 0x80000003), PWM bez muxu PC01/PC03 a vypnutá I2C3, která leží na pinech konzole.
- Dotyk: na stocku teď není žádné vstupní zařízení. Goodix (0x14) ani tlsc6x (0x2e) se nenavázal, protože displej je u této tiskárny fyzicky odpojený. Displej, dotyk a GuppyScreen proto půjde ověřit až po jeho připojení. První start na ně nečeká.

**Záchrana bez J1**
- [ballaswag/ingenic-usbboot](https://github.com/ballaswag/ingenic-usbboot) je psaný přímo pro K1. Nahraje vlastní SPL a U-Boot přes USB v režimu mask-ROM a umí přepnout p1 (`--swap-ota`) nebo číst oddíly. Nepoužívá soubor Creality cloneru, který na deskách S12 podle fóra selhává. Na S12 zatím ověřený není.
- Zkouška bez rizika: přečíst přes USB p1 a porovnat se zálohou. Postup je v `tools/usbboot/README.md`.

## Zkušební start ze slotu 2

Stock běží ze slotu 1 a zůstává tam. Datel OS se zapíše do slotu 2 (p6 a p8) přes SSH skriptem `tools/flash-slot2.sh`.

1. `tools/flash-slot2.sh` jen kontroluje: běží slot 1, ukazatel je `ota:kernel`, netiskne se a obrazy se vejdou.
2. `tools/flash-slot2.sh --write` zapíše jádro a systém, každý oddíl zpětně přečte a porovná MD5. Do `/usr/data/k1os/ssh/authorized_keys` přidá veřejný klíč `~/.ssh/k1_printer_ecdsa.pub`. Ukazatel nemění.
3. `tools/flash-slot2.sh --switch` přepne ukazatel v p1 na `ota:kernel2`. Pak tiskárnu vypni a zapni.

**Zkušební režim.** Hned na začátku startu Datel OS (`k1os-trial-boot.service`, před připojením souborových systémů) přepne ukazatel zpátky na `ota:kernel`. Když se systém kdekoli potom zasekne, stačí vypnout a zapnout a naběhne stock. Na novém systému zůstane tiskárna až po `k1os-slot keep`. `k1os-slot status` ukáže, odkud běží a kam půjde příští start.

**Co tím chráněné není:** zaseknutí jádra dřív, než spustí první službu, například kvůli device tree nebo ovladači eMMC. Pak tiskárna startuje pořád do slotu 2 a vrátit ji jde jen přes USB (`usbboot --swap-ota`, `tools/usbboot/README.md`).

**Co se tím přepíše:** slot 2, kde je teď starší stock 1.3.3.x. Jeho kopie je v záloze v `~/Documents/K1-zaloha-2026-11-05`.

## První starty na tiskárně (7. 11. 2026)

Datel OS nastartoval ze slotu 2 na první pokus: jádro 6.6.157-rt79, eMMC, Wi-Fi se stejnou MAC jako stock, zkušební režim vrací ukazatel na stock. Chyby, které první starty odhalily, a jejich opravy:

| Co selhalo | Příčina | Oprava |
|---|---|---|
| SSH odmítalo klíč | poky na systému jen pro čtení spouští sshd s `sshd_config_readonly`; sshd bere první hodnotu klíčového slova | blok Datel OS je na začátku obou souborů (`openssh_%.bbappend`) |
| Jiná IP (.102) | systemd-networkd se routeru hlásí vygenerovaným ID, ne MAC | `[DHCPv4] ClientIdentifier=mac` v `80-wlan.network` |
| nginx neběžel | `listen [::]:80`, jádro nemá IPv6 | řádek odstraněn z `mainsail.nginx` |
| Moonraker padal při importu | `streaming-form-data` importuje `smart_open` | recept `python3-smart-open` (+ `wrapt` z meta-python) |
| Klipper se restartoval každých 5 s | `klipper_mcu` od Creality nezná `-I`, jednotka padala a `Requires=` zastavovalo Klipper | `klipper_mcu -r`, `Wants=` místo `Requires=` |
| GuppyScreen padal na parsování JSON | otevírá téma pro zápis, na rootu jen pro čtení otevření selže a parsuje prázdný proud | témata se při prvním startu kopírují do `/usr/data/k1os/guppyscreen/themes`; služba má `ConditionPathExists=/dev/fb0` |

**První tisk a FPU (7. 11. 2026):** první pokus spadl na chybě v Creality `virtual_sdcard.py` (proměnné bez výchozí hodnoty, když chybí `user_print_refer.json`; opraveno sedem v receptu a kopií stock nastavení z `creality/userdata/config` při prvním startu). Druhý pokus zhomoval, zahřál a začal tisknout, po pár vteřinách ale MCU vypnulo s „Missed scheduling of next digital out event“. Příčina: hostitelský Klipper trávil 90 % času v jádře, čítače `/sys/kernel/debug/mips/fpuemustats` ukázaly 1,7 miliardy emulovaných instrukcí. FPU XBurst2 má 64bitové registry a jen kódování NaN 2008, legacy režim FR=0 neumí. Tune `mips32r2el` z poky ale staví o32 FP32 ABI s legacy NaN, takže jádro každou FPU instrukci emuluje. Stock userspace je přeložený s `-mfp64 -mnan=2008` (e_flags 0x70001407). Oprava: vlastní tune `mips32r2el-fp64` (`conf/machine/include/tune-mips32r2el-fp64.inc`) a gcc s `--with-fp-32=64 --with-nan=2008`; to znamená přeložit celý userspace znovu. Vedlejší nález: `clock_gettime` stojí 12 µs (OST clocksource pod spinlockem, bez vDSO), proti 1,2 µs za obyčejný syscall.

**Kamera (7. 11. 2026):** kamera Creality (UVC 0c45:6366) dává MJPEG i H.264 v 1080p30 přímo z hardwaru. Obraz obsahuje upstream [pikvm/ustreamer](https://github.com/pikvm/ustreamer) 6.67, který MJPEG jen přeposílá (`--encoder=HW`), služba `ustreamer.service` si uzel kamery najde sama (`camera-device`: uzel s indexem 0 na USB), nginx ho vystavuje na `/webcam/` a `k1os-seed-webcam` kameru jednou zaregistruje v Moonrakeru, takže ji Mainsail ukáže sám. Výchozí je 1280×720 při 15 fps. Fork z NebulaOS není potřeba, ten řeší surový NV12 jiné kamery.

Ověřeno naživo přes SSH: Mainsail přes nginx, Moonraker se všemi komponentami, Klipper ve stavu `ready` s hlavním i tryskovým MCU přes ttyS7 a ttyS1 (přeložený C helper na MIPS funguje), čtení teplot. Chybí `/dev/fb0`, protože ovladač panelu K1 ještě není.

## Větev `feat/kalico`: mainline Klipper (Kalico) a vlastní firmware MCU

Volitelná sestava místo Creality Klipperu. Obraz vybírá proměnná `K1OS_KLIPPER` (`klipper-creality`, výchozí, nebo `kalico`); variantu s Kalicem sestaví `KAS_FILE=kas-creality-k1-kalico.yml ./build.sh`.

| Část | Zdroj | Poznámka |
|---|---|---|
| Hostitel | [pellcorp/kalico](https://github.com/pellcorp/kalico), větev `aug2026` | Kalico s doplňky pro K1: sonda z tenzometrů (`load_cell_probe`, `hx711s`), vstup do bootloaderu MCU |
| Firmware MCU | [pellcorp/k1-kalico-firmware](https://github.com/pellcorp/k1-kalico-firmware), větev `aug2026` | port GD32 od Creality, konfigurace `.config.mcu/.noz/.bed`; překlad toolchainem `gcc-arm-none-eabi` z meta-arm. Vzniknou `mcu0_120_G32-mcu0_021_000.bin`, `noz0_120_G30-noz0_026_000.bin`, `bed0_110_G21-bed0_121_000.bin` s hlavičkou pro bootloader Creality (verze na 0x200, CRC16, délka). |
| Flashování | vlastní `k1os-mcu-flash` | sériový bootloader Creality (ověřeno na tiskárně): 115200 baud, bootloader čeká jen asi 15 s po zapnutí; handshake je jeden bajt 0x75 a bootloader ho přijme jen jednou, pak už zůstává spuštěný bez časového limitu a bere jen rámce `<příkaz><crc>` (verze, velikost sektoru, zápis po sektorech, start aplikace). Kdo se s ním domluví, musí i poslat start, jinak MCU aplikaci nikdy nespustí. Běžící Klipper se do bootloaderu poslat nedá (firmware Creality ani Kalico nemá zapnutý `SERIAL_BOOTLOADER_SIDECHANNEL`), takže aktualizace proběhne jen po vypnutí a zapnutí tiskárny. `k1os-mcu-update.service` běží hned po startu systemd, obsluhuje všechny tři porty najednou (každý vlastním procesem, příkaz `sync`: verze, porovnání, případný zápis, start) a MCU, které už běží aplikaci, přeskočí. Stock si při návratu MCU přeflashuje zpět sám. |
| Konfigurace | `k1os-kalico-config` | jednorázově převede stock konfiguraci: odstraní `prtouch_v2`, `bl24c16f`, `custom_macro`, `fan_feedback`, přepne Z na `probe:z_virtual_endstop`, přidá `k1os_kalico.cfg` se sondou, sítí a náhradami příkazů Creality (`CX_PRINT_LEVELING_CALIBRATION`, `CX_PRINT_DRAW_ONE_LINE`, `PRTOUCH_READY`, …). Záloha původní konfigurace zůstane vedle. |

Čipy MCU: hlavní deska GD32F303xE (120 MHz, `/dev/ttyS7`), tryska GD32F303xB (120 MHz, `/dev/ttyS1`), nivelace GD32E230x8 (72 MHz, `/dev/ttyS9`); všechny 230400 baud, aplikace od 0x8003000.

Licence: Kalico i firmware jsou GPL-3.0. Repozitář pellcorp/creality (instalátor, fragmenty konfigurace, `mcu_util.py`) licenci nemá, proto se z něj nic nepřebírá; flasher i konfigurace jsou vlastní.

Převod konfigurace je ověřený na kopii konfigurace z tiskárny: Kalico ji načte bez chyby a zastaví se až na otevření sériového portu MCU. Aktualizaci MCU dělá balík `k1os-mcu-update` v obou variantách: varianta s Creality Klipperem nese obrazy MCU z repozitáře Creality (`004/003/004`), varianta s Kalicem vlastní (`021/026/121`), takže každá si při startu nahraje firmware, se kterým umí pracovat.

**Nasazení varianty s Kalicem**
1. Ze stocku: `OUT=out/kalico PRINTER=root@<ip> tools/flash-slot2.sh --write`, `--switch`, restart.
2. Při prvním startu `k1os-kalico-config` převede konfiguraci (záloha vedle v `config.creality-<datum>`), `k1os-mcu-update` nahraje nový firmware do tří MCU (asi 10 s, všechny najednou; jen po zapnutí ze studena, po pouhém restartu systému zůstává starý firmware a Kalico se k MCU nepřipojí), pak naběhne Kalico.
3. V Mainsailu: `LOAD_CELL_DIAGNOSTIC`, potom `LOAD_CELL_CALIBRATE` se závažím asi 6 kg (`TARE`, `CALIBRATE GRAMS=6000`, `ACCEPT`, `SAVE_CONFIG`).
4. Input shaper: `SHAPER_CALIBRATE` na tiskárně nejde (výpočet v numpy potřebuje víc než 256 MB RAM, proces skončí OOM a Klipper na něj čeká napořád – pomůže `systemctl restart klipper`). Místo toho `TEST_RESONANCES AXIS=X OUTPUT=raw_data`, totéž pro Y, a na počítači `PRINTER=root@<ip> tools/shaper-fit.sh`; výsledek zapsat do bloku SAVE_CONFIG v `printer.cfg`.
6. Kamera: 720p MJPEG z kamery má při 15 fps ~12 Mbit/s a na slabé Wi-Fi (K1 má jen 2,4 GHz, tady −77 dBm) zahltí linku – UI pak zadrhává. Výchozí je proto 8 fps (~6 Mbit/s) a Mainsail bere přímo stream (`mjpegstreamer`, ne adaptivní snímky). Přenastavit lze v `/usr/data/k1os/camera.env` (`CAMERA_RESOLUTION`, `CAMERA_FPS`) a v Mainsailu u kamery. Vestavěný prohlížeč OrcaSlicer (záložka Device, WebKit) MJPEG stream v obrázku nezobrazí („Error while connecting to …/webcam/?action=stream“), proto je v Moonrakeru i druhá kamera „K1 (snapshots)“ v režimu Adaptive MJPEG-Streamer (5 fps); v Orce ji vyber v rozbalovací nabídce panelu Webcam, Mainsail si volbu pamatuje pro každý prohlížeč zvlášť.
7. Ventilátory K1: `fan0` ofuk výtisku (deska trysky), `fan1` komorový (zadní, s filtrem), `fan2` pomocný boční ofuk. Makra Creality mapují `M106 P<n>` 1:1, takže z Orcy je pomocný `P2` správně; odtah (`P3`) by ale makro Creality poslalo na `fan0`, proto ho převod konfigurace směruje na `fan1`. Posuvníky `output_pin` v Mainsailu posílají surovou PWM bez minima (Creality: fan1 od 50/255, fan2 od 180/255), takže pod tou hodnotou se ventilátor neroztočí.
5. Sonda jede 3 mm/s (stejně opakovatelné jako 1 mm/s, mesh o 40 % rychlejší); `homing_speed` osy Z je stejná, aby G28 Z a mesh měly jednu referenci.
4. `G28`, `PROBE_ACCURACY`, nastavení `z_offset` sondy, `BED_MESH_CALIBRATE`.
8. Po teplém restartu ze stocku do Datel OS (cesta při flashování: `k1os-slot release`, reboot, zápis, `--switch`, reboot) zůstane hlavní MCU ve stavu shutdown a Kalico ohlásí „Can not update MCU 'mcu' config as it is shutdown“. Jeden `FIRMWARE_RESTART` to srovná (asi 20 s); při běžném startu Datel OS se to neděje.
5. Návrat: vypnout a zapnout (zkušební režim) vrátí stock, který si firmware MCU přeflashuje na svůj.

## Fáze

0. **Záchrana:** připravit nahrávání přes USB (Ingenic cloner) a zálohu celé eMMC. Bez toho se nic nenahrává.
1. **První boot:** jádro a minimální systém do neaktivního slotu. Cíl je konzole na ttyS2, SSH, Wi-Fi a připojené `/usr/data`.
2. **Tisk:** Klipper, Moonraker a Mainsail, zatím se stock firmwarem MCU. Senzor prtouch jako rozšíření Klipperu podle zdrojů Creality.
3. **Displej:** ovladač panelu K1 (inicializace ze stock modulů `lcd_*.ko`) a dotyková aplikace v LVGL, vycházející z GuppyScreen a NebulaScreen.
4. **MCU:** otevřený Klipper pro hlavní desku GD32F303 (nahrání přes SWD a OpenOCD), pro hlavu GD32F303 a pro desku senzoru GD32E230.
5. **Aktualizace:** vlastní A/B updater s automatickým návratem.
