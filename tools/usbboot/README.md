# Zkouška USB záchrany K1 (jen čtení)

Nástroj: [ballaswag/ingenic-usbboot](https://github.com/ballaswag/ingenic-usbboot), commit c65eaa3.
Do eMMC zapisuje jen `--swap-ota` (oddíl p1). Čtení oddílů nic nemění.

## Sestavení na Macu

```bash
brew install libusb pkg-config
git clone https://github.com/ballaswag/ingenic-usbboot.git ~/k1-usbboot
cd ~/k1-usbboot && git checkout c65eaa337cc9fb64fd8a2ea22bcf3f9395c9945c && make
```

## Zkouška

1. Propoj port MicroUSB na základní desce s Macem. Kabel musí přenášet data, ne jen nabíjet. Port je na horní hraně desky vlevo, tlačítka RESET a BOOT na stejné hraně vpravo (obrázek 3 v [návodu Creality](https://wiki.creality.com/en/k1-flagship-series/k1/quick-start-guide/brick-rescue-wire-brushing-process)).
2. Tiskárna musí být zapnutá, deska potřebuje napájení 24 V. Netiskni, tlačítka ji resetují.
3. Drž BOOT i RESET asi 3 s, pusť RESET a pak BOOT. Systémová LED slabě svítí a deska čeká v režimu mask-ROM.
4. Na Macu zkontroluj, že je deska vidět jako „Ingenic USB BOOT DEVICE“ (a108:eaef):

```bash
system_profiler SPUSBDataType | grep -i -A3 ingenic
```

Pak pokračuj čtením p1:
5. Spusť U-Boot do RAM a přečti oddíl p1 (offset 0x100000, 1 MiB):

```bash
cd ~/k1-usbboot && sudo ./usbboot --uboot && sudo ./usbboot -o 0x100000 -s 0x100000 --dump-partition ./ota.out
```

6. Porovnej se zálohou. Obě čísla musí být stejná:

```bash
md5 -q ~/k1-usbboot/ota.out; dd if=~/Documents/K1-zaloha-2026-11-05/mmcblk0-sectors-0-1488895.bin bs=512 skip=2048 count=2048 2>/dev/null | md5 -q
```

7. Stiskni RESET. Tiskárna normálně nastartuje stock.

Shoda znamená, že USB záchrana na této desce S12 funguje. Pak jde případný nefunkční slot 2 vrátit příkazem `sudo ./usbboot --uboot && sudo ./usbboot --swap-ota`.
