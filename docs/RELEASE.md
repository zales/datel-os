# Datel OS releases

Development happens in the private repository `zales/k1-yocto`; the public repository [`zales/datel-os`](https://github.com/zales/datel-os) receives the code and the images at every release. A release is a tag `vX.Y.Z` in the private repository. The workflow `.github/workflows/release.yml` builds the image from it, checks the files, pushes the tagged commit with its history and the tag to the public repository's `main`, and creates the GitHub Release there with notes generated from the commits since the previous tag. All steps are done by `tools/release.sh`, so the same can be run by hand.

**Token.** The workflow writes to the public repository with the secret `DATEL_OS_TOKEN` of the private repository: a fine-grained personal access token (GitHub, Settings, Developer settings, Fine-grained tokens) with *Repository access* limited to `datel-os` and the permissions *Contents: Read and write* and *Workflows: Read and write* (the mirrored history contains `.github/workflows/release.yml`, and GitHub refuses a push of workflow files without it). Set it with `gh secret set DATEL_OS_TOKEN -R zales/k1-yocto`. Without it the `publish` job stops before touching anything. The mirrored workflow file never runs in the public repository (every job checks the repository name).

## What a release contains

| File | Contents | Where it goes |
|---|---|---|
| `datel-os-vX.Y.Z-xImage` | Linux 6.6-rt kernel in the Ingenic `xImage` format | mmcblk0p5 / p6 |
| `datel-os-vX.Y.Z-rootfs.squashfs` | the system with Kalico and its own MCU firmware | mmcblk0p7 / p8 |
| `datel-os-vX.Y.Z.ota.img` | the same packed as a package for the Creality updater (7z, AES); the version inside is `9.X.Y.Z` | the inactive slot |
| `SHA256SUMS` | checksums of all files | |

**What a release never contains:** the bootloader (neither the SPL nor U-Boot, nor the open one from branch `feat/uboot`, which is not verified on the printer), the RTOS `zero.bin` for the third core, and anything for partition `mmcblk0p9`. `tools/release.sh check` refuses every file outside the list above and additionally opens each `.ota.img` to verify that it contains only the kernel and system chunks and that `ota_update.in` installs only `kernel` and `rootfs`. The stock bootloader therefore stays in place and the way back to stock in the other slot keeps working.

The tag version has to match `DISTRO_VERSION` in `meta-creality-k1/conf/distro/k1os.conf`: it produces the OTA package version `9.X.Y.Z` (the nine so that it is higher than stock 1.3.x) and the name `CR4CU220812S11_ota_img_V9.X.Y.Z.img`. When they do not match, the workflow stops in its first step, before the build.

## Where it is built and why

The build runs on a **self-hosted runner on the NAS `zlsnas`** (Raspberry Pi 5, Debian 13, Docker, NVMe), the same way as on the Mac: `./build.sh` in Docker with the volume `k1yocto-work`, which holds the `sstate-cache` and `downloads`. The volume was created as a copy of the Mac's; both machines build in a linux/arm64 container (`BUILD_SYS = aarch64-linux`), so the sstate is portable between them and a release from a tag takes minutes. The exact tagged tree is built, not a working copy. Publishing is done by an ordinary GitHub runner (`ubuntu-latest`), which only checks and uploads.

The NAS is always on, the Mac is not; that is why the runner lives there. GitHub's own runner is not enough for the build: a clean Yocto build takes several hours on 4 cores (the job limit is 6 hours), needs more than 30 GB of space (the runner has 14 GB) and the `sstate-cache` does not fit the 10 GB Actions cache. Larger runners cost money.

Without a running runner a tag breaks nothing: the job waits in the queue (up to 24 hours) until the runner comes up, then runs.

### The runner on zlsnas

It is installed in `~zales/actions-runner` as the systemd service `actions.runner.zales-k1-yocto.zlsnas`, name `zlsnas`, label **`k1-yocto`** (the workflow asks for it with `runs-on: [self-hosted, k1-yocto]`). It runs as user `zales` in the `docker` group.

```bash
ssh zlsnas.local 'cd actions-runner && sudo ./svc.sh status'
```

`./build.sh` takes the number of bitbake threads and `make -j` from the host's core count (4 on the Pi; `JOBS=` overrides it) and starts the container with `--cpu-shares 512`, so under contention it yields to the other containers on the NAS (Home Assistant and friends). A cache hit takes minutes; compiling the kernel or gcc after a tune change takes several times longer on the Pi than on the Mac, but it completes.

A new runner elsewhere (or again on the NAS): GitHub → repository → *Settings* → *Actions* → *Runners* → *New self-hosted runner*, give the label `k1-yocto` during `./config.sh`, then `sudo ./svc.sh install <user> && sudo ./svc.sh start`. The runner stores the `PATH` from configuration time in `.path`; `docker` has to be in it. Before the first build copy `sstate-cache` and `downloads` from an existing volume, otherwise it builds from scratch (hours):

```bash
docker run --rm -v k1yocto-work:/work:ro busybox tar cf - -C /work/k1-yocto/build sstate-cache downloads | ssh <host> 'docker run --rm -i -v k1yocto-work:/work busybox sh -c "mkdir -p /work/k1-yocto/build && tar xf - -C /work/k1-yocto/build && chown -R 30000:30000 /work/k1-yocto"'
```

The runner and a manual `./build.sh` on the same machine use one volume; bitbake locks it, so two builds do not start at once. The Mac keeps its own volume for development; changes in the `sstate-cache` are not synchronised between machines, each fills its own.

## How to cut a release

1. Bump `DISTRO_VERSION` in `meta-creality-k1/conf/distro/k1os.conf` (and `DISTRO_CODENAME` if you like), commit to `main`.
2. Tag and push the tag:

```bash
git tag -a v0.3.0 -m "Datel OS 0.3.0"
```

```bash
git push origin v0.3.0
```

3. Watch *Actions* → *Release firmware*. The job `build` builds the image, the job `publish` checks the files, mirrors the code and creates the Release `Datel OS v0.3.0` in the public repository. A tag with a hyphen (`v0.3.0-rc1`) becomes a *pre-release*; the version before the hyphen still has to match `DISTRO_VERSION`.

A release can be repeated by hand through *Actions* → *Release firmware* → *Run workflow* with the name of an existing tag; the files in the Release are overwritten and the notes regenerated.

### By hand without the runner

The same thing the workflow does, on the Mac or on the NAS (needs `7zz`, on the Mac `brew install sevenzip`):

```bash
TAG=v0.3.0 tools/release.sh build
```

```bash
TAG=v0.3.0 tools/release.sh check
```

```bash
TAG=v0.3.0 tools/release.sh notes > /tmp/notes.md && gh release create v0.3.0 release/* --verify-tag --title "Datel OS v0.3.0" --notes-file /tmp/notes.md
```

`build` builds the image, copies the files from the Docker volume into `release/` (the directory is in `.gitignore`) and writes `SHA256SUMS`. `collect` only does the copying from whatever is in the deploy directory right now; useful when the build is already done.

## Installing on the printer

Datel OS is written into the slot the printer is not running from: from stock (slot 1) into slot 2 (`mmcblk0p6` + `mmcblk0p8`), from a running Datel OS into the other slot according to `SLOT=`. The full procedure with backup, trial boot and recovery is in [INSTALL.md](INSTALL.md); this section is the short form with files from the Release.

**Prerequisite:** root over SSH on the printer with the key `~/.ssh/k1_printer_ecdsa`. On stock the key is copied once with `ssh-copy-id -i ~/.ssh/k1_printer_ecdsa.pub root@<ip>` (Creality gives the stock root password in its rooting guide; Datel OS keeps the same root password); Datel OS then takes the key over from `/usr/data/k1os/ssh/authorized_keys`. The printer must not be printing.

1. Download the release files and verify the checksums:

```bash
gh release download v0.3.0 -R zales/datel-os -D dl/ && (cd dl && shasum -a 256 -c SHA256SUMS)
```

2. Write, verify and switch the marker. From stock into slot 2 (`PRINTER=root@<ip>`):

```bash
KERNEL=dl/datel-os-v0.3.0-xImage ROOTFS=dl/datel-os-v0.3.0-rootfs.squashfs PRINTER=root@192.168.1.102 tools/flash-slot2.sh --write
```

```bash
KERNEL=dl/datel-os-v0.3.0-xImage ROOTFS=dl/datel-os-v0.3.0-rootfs.squashfs PRINTER=root@192.168.1.102 tools/flash-slot2.sh --switch
```

   From a running Datel OS into the other slot add `SLOT=1` or `SLOT=2` (the one the printer is not running from; the script checks this and refuses to write into the running one). Without `--write` the script only checks and writes nothing.

3. Restart (from stock power off and on, from Datel OS a `reboot` is enough). The new system comes up in trial mode: the first thing after start points the marker in p1 at the other slot, so a hang or a power cycle brings the previous system back. Once you are happy, run `k1os-slot keep` on the printer; `k1os-slot status` shows where it runs from and where the next boot goes. If `keep` is already in effect from before, the new slot inherits it (the `boot-keep` file lives in `/usr/data`, shared by both slots).

4. On the first start after a warm restart from stock into Datel OS the main MCU stays in shutdown and Klipper reports a configuration error; one `FIRMWARE_RESTART` sorts it out. Between two Datel OS slots this does not happen.

Datel OS loads its own firmware into all three MCUs on the first cold start (about 10 s); on the way back stock reflashes the MCU firmware itself. Details on probe calibration and input shaping are in [KALICO.md](KALICO.md).

**Datel OS in both slots.** Once you overwrite the second slot too, stock disappears from the printer and A/B serves Datel OS alone. Back up the stock partitions p1–p5 and p7 first (`ssh root@<ip> dd if=/dev/mmcblk0pN bs=1M > mmcblk0pN.bin`, about 330 MB, compare the MD5 with `md5sum /dev/mmcblk0pN` on the printer); the way back to stock is writing those files back from a running Datel OS. Without stock on the printer the display does not work (Datel OS has no panel driver yet).

**The `.ota.img` package** is the format installed by the stock Creality updater and by the future own updater (phase 5). The updater expects a file named like the directory inside it, so rename it to `CR4CU220812S11_ota_img_V9.X.Y.Z.img` before use (the exact name is in the release notes). Installing through the stock updater has not been tried on the printer yet; the verified path is `tools/flash-slot2.sh`.
