# Vydání Datel OS

Vydání je tag `vX.Y.Z` v tomto repozitáři. Workflow `.github/workflows/release.yml` z něj sestaví obě varianty obrazu, zkontroluje je a zveřejní jako GitHub Release s poznámkami vygenerovanými z commitů od minulého tagu. Všechny kroky dělá `tools/release.sh`, takže to samé jde spustit i ručně.

## Co vydání obsahuje

| Soubor | Obsah | Kam patří |
|---|---|---|
| `datel-os-vX.Y.Z-xImage` | jádro Linux 6.6-rt ve formátu Ingenic `xImage`, společné oběma variantám | mmcblk0p5 / p6 |
| `datel-os-vX.Y.Z-klipper-creality.squashfs` | systém s Klipperem od Creality a stock firmwarem MCU | mmcblk0p7 / p8 |
| `datel-os-vX.Y.Z-kalico.squashfs` | systém s Kalicem a vlastním firmwarem MCU | mmcblk0p7 / p8 |
| `datel-os-vX.Y.Z-<varianta>.ota.img` | totéž zabalené jako balík pro aktualizátor Creality (7z, AES); verze uvnitř je `9.X.Y.Z` | neaktivní slot |
| `SHA256SUMS` | kontrolní součty všech souborů | |

**Co vydání nikdy neobsahuje:** bootloader (SPL ani U-Boot, ani ten otevřený z větve `feat/uboot`, který na tiskárně není ověřený), RTOS `zero.bin` pro třetí jádro a cokoli pro oddíl `mmcblk0p9`. `tools/release.sh check` odmítne každý soubor mimo seznam výše a navíc otevře každý `.ota.img` a ověří, že uvnitř jsou jen bloky jádra a systému a `ota_update.in` instaluje jen `kernel` a `rootfs`. Stock bootloader tak zůstává na místě a návrat ke stocku ve druhém slotu funguje dál.

Verze tagu musí sedět s `DISTRO_VERSION` v `meta-creality-k1/conf/distro/k1os.conf`: z ní vzniká verze OTA balíku `9.X.Y.Z` (devítka proto, aby byla vyšší než stock 1.3.x) a jméno `CR4CU220812S11_ota_img_V9.X.Y.Z.img`. Když nesedí, workflow skončí hned v prvním kroku, ještě před buildem.

## Kde se staví a proč

Build běží na **self-hosted runneru na tvém Macu**, tedy tam, kde se staví dnes: `./build.sh` v Dockeru s volume `k1yocto-work`, ve které je sdílená `sstate-cache` (9 GB) a `downloads` (4,6 GB). Díky tomu vydání z tagu trvá minuty, ne hodiny, a sestavuje se přesně otagovaný strom, ne to, co máš zrovna rozpracované. Zveřejnění pak dělá obyčejný runner GitHubu (`ubuntu-latest`), ten jen kontroluje a nahrává.

Runner od GitHubu na build nestačí: čistý build Yocta je několik hodin na 4 jádrech (limit jobu je 6 hodin), potřebuje přes 30 GB místa (runner má 14 GB) a `sstate-cache` se do 10GB cache Actions nevejde. Větší runnery jsou placené. Pro soukromý repozitář jednoho člověka se self-hosted runner nevyplatí nahrazovat.

Bez běžícího runneru tag nic nerozbije: job čeká ve frontě (až 24 hodin), dokud runner nenaběhne, a pak proběhne.

### Runner: jednorázové nastavení

Na Macu musí běžet Docker Desktop. Runner je obyčejný proces pod tvým účtem, nic nepotřebuje práva správce.

1. GitHub → repozitář → *Settings* → *Actions* → *Runners* → *New self-hosted runner* → macOS, ARM64. Stránka ukáže příkazy ke stažení a `./config.sh` s čerstvým tokenem.
2. Při `./config.sh` zadej label **`k1-yocto`** (na to se workflow ptá přes `runs-on: [self-hosted, k1-yocto]`), ostatní nech výchozí. Spouštěj ho z terminálu, kde je `docker` v `PATH`: runner si `PATH` z té chvíle uloží do `.path` a používá ho pro joby.
3. Spuštění: buď jen při vydání ručně `./run.sh` (po skončení jobu ho ukonči Ctrl-C), nebo trvale jako služba `./svc.sh install && ./svc.sh start`.

Runner i tvoje ruční `./build.sh` používají stejnou volume; bitbake si ji zamkne, takže dva buildy najednou se nespustí, druhý počká nebo spadne. Během vydání nestav ručně. `tools/release.sh` obalí build do `caffeinate -i`, aby Mac mezitím neusnul.

## Jak vydat verzi

1. Zvyš `DISTRO_VERSION` v `meta-creality-k1/conf/distro/k1os.conf` (a případně `DISTRO_CODENAME`), commitni do `main`.
2. Spusť runner, pokud neběží jako služba.
3. Otaguj a pošli tag:

```bash
git tag -a v0.3.0 -m "Datel OS 0.3.0"
```

```bash
git push origin v0.3.0
```

4. Sleduj *Actions* → *Release firmware*. Job `build` staví `klipper-creality` a potom `kalico` (obě varianty sdílejí build adresář, proto po sobě), job `publish` zkontroluje soubory a vytvoří Release `Datel OS v0.3.0`. Tag s pomlčkou (`v0.3.0-rc1`) vznikne jako *pre-release*; verze před pomlčkou musí pořád sedět s `DISTRO_VERSION`.

Vydání jde zopakovat ručně přes *Actions* → *Release firmware* → *Run workflow* s názvem existujícího tagu; soubory v Release se přepíšou a poznámky obnoví.

### Ručně bez runneru

Totéž, co dělá workflow, na Macu:

```bash
TAG=v0.3.0 tools/release.sh build
```

```bash
TAG=v0.3.0 tools/release.sh check
```

```bash
TAG=v0.3.0 tools/release.sh notes > /tmp/notes.md && gh release create v0.3.0 release/* --verify-tag --title "Datel OS v0.3.0" --notes-file /tmp/notes.md
```

`build` staví obě varianty a po každé zkopíruje obrazy z Docker volume do `release/` (adresář je v `.gitignore`), nakonec zapíše `SHA256SUMS`. `collect <varianta>` udělá jen kopírování z toho, co je v deploy adresáři zrovna teď; hodí se, když už je build hotový.

## Instalace na tiskárnu

Datel OS se zapisuje do slotu 2 (`mmcblk0p6` + `mmcblk0p8`), stock zůstává ve slotu 1. Postup je stejný jako v README, jen soubory jsou z Release.

1. Na tiskárně běží stock ze slotu 1. Když zrovna běží Datel OS, vypni a zapni tiskárnu (zkušební režim vrátí stock); pokud jsi dřív spustil `k1os-slot keep`, nejdřív na Datel OS zadej `k1os-slot release` a pak restartuj.
2. Stáhni soubory vydání a ověř součty:

```bash
gh release download v0.3.0 -R zales/k1-yocto -D dl/ && (cd dl && shasum -a 256 -c SHA256SUMS)
```

3. Zapiš slot 2, ověř a přepni ukazatel (`PRINTER=root@<ip>`, klíč `~/.ssh/k1_printer_ecdsa`):

```bash
KERNEL=dl/datel-os-v0.3.0-xImage ROOTFS=dl/datel-os-v0.3.0-klipper-creality.squashfs PRINTER=root@192.168.1.104 tools/flash-slot2.sh --write
```

```bash
KERNEL=dl/datel-os-v0.3.0-xImage ROOTFS=dl/datel-os-v0.3.0-klipper-creality.squashfs PRINTER=root@192.168.1.104 tools/flash-slot2.sh --switch
```

4. Vypni a zapni tiskárnu. Datel OS naběhne ve zkušebním režimu: první věc po startu přepne ukazatel v p1 zpátky na stock, takže další vypnutí a zapnutí vrátí stock. Až budeš s verzí spokojený, na tiskárně `k1os-slot keep`; `k1os-slot status` ukáže, odkud běží a kam půjde příští start.

Varianta `kalico` při prvním studeném startu nahraje vlastní firmware do všech tří MCU (asi 10 s); při návratu si stock firmware MCU přeflashuje zpět sám. Podrobnosti o kalibraci sondy a input shaperu jsou v README.

**Balík `.ota.img`** je formát, který instaluje stock aktualizátor Creality i budoucí vlastní updater (fáze 5). Aktualizátor čeká soubor pojmenovaný stejně jako adresář uvnitř, proto ho před použitím přejmenuj na `CR4CU220812S11_ota_img_V9.X.Y.Z.img` (přesné jméno je v poznámkách k vydání). Instalace přes stock aktualizátor zatím není na tiskárně vyzkoušená; ověřená cesta je `tools/flash-slot2.sh`.

**Aktualizace z běžícího Datel OS** do druhého slotu zatím není: druhý slot je stock a `flash-slot2.sh` odmítne zapisovat, pokud neběží ze slotu 1. Vlastní A/B updater s automatickým návratem je fáze 5.
