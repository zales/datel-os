#!/usr/bin/env python3
"""Split images into a Creality K1 OTA directory and verify one.

Layout that local_ota_update.sh expects (firmware 1.3.x):
  <name>/ota_config.in                      current_version=<ver>
  <name>/ota_v<ver>/ota_v<ver>.ok
  <name>/ota_v<ver>/ota_update.in           ota_version + img_type/name/size/md5 blocks
  <name>/ota_v<ver>/ota_md5_<img>.<md5>     md5 of every chunk, one per line
  <name>/ota_v<ver>/<img>.<NNNN>.<prev>     1 MiB chunks; <prev> is the md5 of the
                                            previous chunk, the whole-image md5 for chunk 0
The directory is then packed as an AES-encrypted 7z named <name>.img.
"""
import argparse
import hashlib
import os
import sys

CHUNK = 1024 * 1024
ORDER = [("kernel", "xImage"), ("rootfs", "rootfs.squashfs"), ("rtos", "zero.bin")]


def md5(b):
    return hashlib.md5(b).hexdigest()


def pack(images_dir, out_dir, version):
    vdir = os.path.join(out_dir, "ota_v" + version)
    os.makedirs(vdir, exist_ok=False)
    with open(os.path.join(out_dir, "ota_config.in"), "w") as f:
        f.write("current_version=%s\n" % version)
    with open(os.path.join(vdir, "ota_v%s.ok" % version), "w") as f:
        f.write("\n")
    upd = ["ota_version=%s" % version, ""]
    for typ, name in ORDER:
        path = os.path.join(images_dir, name)
        if not os.path.exists(path):
            continue  # e.g. no RTOS image: the slot keeps the RTOS it has
        data = open(path, "rb").read()
        whole = md5(data)
        prev, sums = whole, []
        for i in range(0, len(data), CHUNK):
            part = data[i:i + CHUNK]
            with open(os.path.join(vdir, "%s.%04d.%s" % (name, i // CHUNK, prev)), "wb") as f:
                f.write(part)
            prev = md5(part)
            sums.append(prev)
        with open(os.path.join(vdir, "ota_md5_%s.%s" % (name, whole)), "w") as f:
            f.write("\n".join(sums) + "\n")
        upd += ["img_type=" + typ, "img_name=" + name, "img_size=%d" % len(data),
                "img_md5=" + whole, ""]
    with open(os.path.join(vdir, "ota_update.in"), "w") as f:
        f.write("\n".join(upd))


def verify(out_dir, extract_to=None):
    cfg = dict(l.strip().split("=", 1) for l in open(os.path.join(out_dir, "ota_config.in")) if "=" in l)
    version = cfg["current_version"]
    vdir = os.path.join(out_dir, "ota_v" + version)
    assert os.path.exists(os.path.join(vdir, "ota_v%s.ok" % version)), "missing .ok file"
    imgs, cur = [], None
    for l in open(os.path.join(vdir, "ota_update.in")):
        l = l.strip()
        if "=" not in l:
            continue
        k, v = l.split("=", 1)
        if k == "ota_version":
            assert v == version, "ota_version %s != current_version %s" % (v, version)
        elif k == "img_type":
            cur = {"type": v}
            imgs.append(cur)
        else:
            cur[k] = v
    ok = True
    for im in imgs:
        name, whole, size = im["img_name"], im["img_md5"], int(im["img_size"])
        sums = open(os.path.join(vdir, "ota_md5_%s.%s" % (name, whole))).read().split()
        prev, h, total = whole, hashlib.md5(), 0
        fo = open(os.path.join(extract_to, name), "wb") if extract_to else None
        for i, expect in enumerate(sums):
            part = open(os.path.join(vdir, "%s.%04d.%s" % (name, i, prev)), "rb").read()
            got = md5(part)
            if got != expect:
                ok = False
                print("chunk md5 mismatch: %s.%04d" % (name, i))
            h.update(part)
            total += len(part)
            prev = got
            if fo:
                fo.write(part)
        good = total == size and h.hexdigest() == whole
        ok = ok and good
        print("%-16s %-6s chunks=%3d size=%d md5=%s %s" % (name, im["type"], len(sums), total, whole, "OK" if good else "BAD"))
    print("version", version, "OK" if ok else "FAILED")
    return ok


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pack")
    p.add_argument("images_dir")
    p.add_argument("out_dir")
    p.add_argument("version")
    v = sub.add_parser("verify")
    v.add_argument("out_dir")
    v.add_argument("--extract-to")
    a = ap.parse_args()
    if a.cmd == "pack":
        pack(a.images_dir, a.out_dir, a.version)
    else:
        sys.exit(0 if verify(a.out_dir, a.extract_to) else 1)
