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

Build běží na **self-hosted runneru na NASu `zlsnas`** (Raspberry Pi 5, Debian 13, Docker, NVMe), stejně jako na Macu: `./build.sh` v Dockeru s volume `k1yocto-work`, ve které je `sstate-cache` a `downloads`. Volume vznikla kopií té z Macu; oba stroje staví v kontejneru linux/arm64 (`BUILD_SYS = aarch64-linux`), takže sstate je mezi nimi přenosná a vydání z tagu trvá minuty. Staví se přesně otagovaný strom, ne rozpracovaná kopie. Zveřejnění dělá obyčejný runner GitHubu (`ubuntu-latest`), ten jen kontroluje a nahrává.

NAS běží pořád, Mac ne; proto je runner tam. Runner od GitHubu na build nestačí: čistý build Yocta je několik hodin na 4 jádrech (limit jobu je 6 hodin), potřebuje přes 30 GB místa (runner má 14 GB) a `sstate-cache` se do 10GB cache Actions nevejde. Větší runnery jsou placené.

Bez běžícího runneru tag nic nerozbije: job čeká ve frontě (až 24 hodin), dokud runner nenaběhne, a pak proběhne.

### Runner na zlsnas

Je nainstalovaný v `~zales/actions-runner` jako služba systemd `actions.runner.zales-k1-yocto.zlsnas`, jméno `zlsnas`, label **`k1-yocto`** (workflow ho žádá přes `runs-on: [self-hosted, k1-yocto]`). Běží pod uživatelem `zales` ve skupině `docker`.

```bash
ssh zlsnas.local 'cd actions-runner && sudo ./svc.sh status'
```

`./build.sh` bere počet vláken bitbake a `make -j` z počtu jader hostitele (na Pi 4; `JOBS=` to přebije) a kontejner spouští s `--cpu-shares 512`, takže při souběhu ustoupí ostatním kontejnerům na NASu (Home Assistant a spol.). Cache hit trvá minuty; překlad jádra nebo gcc po změně tune trvá na Pi několikanásobně déle než na Macu, ale proběhne.

Nový runner jinde (nebo znovu na NASu): GitHub → repozitář → *Settings* → *Actions* → *Runners* → *New self-hosted runner*, při `./config.sh` zadat label `k1-yocto`, potom `sudo ./svc.sh install <uživatel> && sudo ./svc.sh start`. Runner si uloží `PATH` z chvíle konfigurace do `.path`; `docker` v něm musí být. Před prvním buildem zkopíruj `sstate-cache` a `downloads` z existující volume, jinak se staví od nuly (hodiny):

```bash
docker run --rm -v k1yocto-work:/work:ro busybox tar cf - -C /work/k1-yocto/build sstate-cache downloads | ssh <stroj> 'docker run --rm -i -v k1yocto-work:/work busybox sh -c "mkdir -p /work/k1-yocto/build && tar xf - -C /work/k1-yocto/build && chown -R 30000:30000 /work/k1-yocto"'
```

Runner a ruční `./build.sh` na stejném stroji používají jednu volume; bitbake si ji zamkne, takže dva buildy najednou se nespustí. Na Macu zůstává vlastní volume pro vývoj; změny v `sstate-cache` se mezi stroji nesynchronizují, každý si ji plní sám.

## Jak vydat verzi

1. Zvyš `DISTRO_VERSION` v `meta-creality-k1/conf/distro/k1os.conf` (a případně `DISTRO_CODENAME`), commitni do `main`.
2. Otaguj a pošli tag:

```bash
git tag -a v0.3.0 -m "Datel OS 0.3.0"
```

```bash
git push origin v0.3.0
```

3. Sleduj *Actions* → *Release firmware*. Job `build` staví `klipper-creality` a potom `kalico` (obě varianty sdílejí build adresář, proto po sobě), job `publish` zkontroluje soubory a vytvoří Release `Datel OS v0.3.0`. Tag s pomlčkou (`v0.3.0-rc1`) vznikne jako *pre-release*; verze před pomlčkou musí pořád sedět s `DISTRO_VERSION`.

Vydání jde zopakovat ručně přes *Actions* → *Release firmware* → *Run workflow* s názvem existujícího tagu; soubory v Release se přepíšou a poznámky obnoví.

### Ručně bez runneru

Totéž, co dělá workflow, na Macu nebo na NASu (potřebuje `7zz`, na Macu `brew install sevenzip`):

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

Datel OS se zapisuje do slotu, ze kterého tiskárna zrovna neběží: ze stocku (slot 1) do slotu 2 (`mmcblk0p6` + `mmcblk0p8`), z běžícího Datel OS do druhého slotu podle `SLOT=`. Postup je stejný jako v README, jen soubory jsou z Release.

**Předpoklad:** root přes SSH na tiskárně klíčem `~/.ssh/k1_printer_ecdsa`. Na stocku se klíč nahraje jednou přes `ssh-copy-id -i ~/.ssh/k1_printer_ecdsa.pub root@<ip>` (heslo roota stock firmwaru uvádí Creality v návodu k rootování), Datel OS ho pak převezme z `/usr/data/k1os/ssh/authorized_keys`. Tiskárna nesmí tisknout.

1. Stáhni soubory vydání a ověř součty:

```bash
gh release download v0.3.0 -R zales/k1-yocto -D dl/ && (cd dl && shasum -a 256 -c SHA256SUMS)
```

2. Zapiš, ověř a přepni ukazatel. Ze stocku do slotu 2 (`PRINTER=root@<ip>`):

```bash
KERNEL=dl/datel-os-v0.3.0-xImage ROOTFS=dl/datel-os-v0.3.0-kalico.squashfs PRINTER=root@192.168.1.102 tools/flash-slot2.sh --write
```

```bash
KERNEL=dl/datel-os-v0.3.0-xImage ROOTFS=dl/datel-os-v0.3.0-kalico.squashfs PRINTER=root@192.168.1.102 tools/flash-slot2.sh --switch
```

   Z běžícího Datel OS do druhého slotu přidej `SLOT=1` nebo `SLOT=2` (ten, ze kterého tiskárna neběží; skript to kontroluje a odmítne zapsat do běžícího). Bez `--write` skript jen kontroluje a nic nezapisuje.

3. Restartuj (ze stocku vypni a zapni, z Datel OS stačí `reboot`). Nový systém naběhne ve zkušebním režimu: první věc po startu přepne ukazatel v p1 na druhý slot, takže zaseknutí nebo vypnutí a zapnutí vrátí předchozí systém. Až budeš spokojený, na tiskárně `k1os-slot keep`; `k1os-slot status` ukáže, odkud běží a kam půjde příští start. Když už `keep` platí z dřívějška, nový slot ho převezme (soubor `boot-keep` je v `/usr/data`, společném oběma slotům).

4. Při prvním startu po přechodu ze stocku do Datel OS teplým restartem zůstane hlavní MCU ve stavu shutdown a Klipper ohlásí chybu konfigurace; jeden `FIRMWARE_RESTART` to srovná. Mezi dvěma slot Datel OS se to neděje.

Varianta `kalico` při prvním studeném startu nahraje vlastní firmware do všech tří MCU (asi 10 s); při návratu si stock firmware MCU přeflashuje zpět sám. Podrobnosti o kalibraci sondy a input shaperu jsou v README.

**Datel OS v obou slotech.** Jakmile druhý slot přepíšeš taky, stock z tiskárny zmizí a A/B slouží jen Datel OS. Předtím zálohuj stock oddíly p1–p5 a p7 (`ssh root@<ip> dd if=/dev/mmcblk0pN bs=1M > mmcblk0pN.bin`, asi 330 MB, MD5 porovnej s `md5sum /dev/mmcblk0pN` na tiskárně); návrat ke stocku je zápis těchto souborů zpět ze spuštěného Datel OS. Bez stocku na tiskárně neběží displej (Datel OS zatím nemá ovladač panelu).

**Balík `.ota.img`** je formát, který instaluje stock aktualizátor Creality i budoucí vlastní updater (fáze 5). Aktualizátor čeká soubor pojmenovaný stejně jako adresář uvnitř, proto ho před použitím přejmenuj na `CR4CU220812S11_ota_img_V9.X.Y.Z.img` (přesné jméno je v poznámkách k vydání). Instalace přes stock aktualizátor zatím není na tiskárně vyzkoušená; ověřená cesta je `tools/flash-slot2.sh`.
