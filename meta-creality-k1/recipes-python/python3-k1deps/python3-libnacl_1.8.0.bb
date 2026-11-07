SUMMARY = "ctypes wrapper for libsodium"
HOMEPAGE = "https://github.com/saltstack/libnacl"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=1cb1960468b1cf32de0c44f78d390f44"

SRC_URI[sha256sum] = "f1037b85ca31fd8b02c43d66f78c2049bc58480e6a395dc9d27e6821b5fe185d"

inherit pypi setuptools3

# libnacl 1.8.0 looks for libsodium.so.{23,18,...}; meta-oe ships soname 26.
do_configure:prepend() {
    sed -i 's/__SONAMES = (23,/__SONAMES = (26, 23,/' ${S}/libnacl/__init__.py
}

RDEPENDS:${PN} += "libsodium python3-core python3-ctypes"
