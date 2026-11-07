SUMMARY = "ctypes wrapper for libsodium"
HOMEPAGE = "https://github.com/saltstack/libnacl"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=9c8a70e4958da99fa55f2fa83dd35c8d"

SRC_URI[sha256sum] = "f3418da7df29e6d9b11fd7d990289d16397dc1020e4e35192e11aee826922860"

inherit pypi python_poetry_core

# libnacl 1.8.0 looks for libsodium.so.{23,18,...}; meta-oe ships soname 26.
do_configure:prepend() {
    sed -i 's/__SONAMES = (23,/__SONAMES = (26, 23,/' ${S}/libnacl/__init__.py
}

RDEPENDS:${PN} += "libsodium python3-core python3-ctypes"
