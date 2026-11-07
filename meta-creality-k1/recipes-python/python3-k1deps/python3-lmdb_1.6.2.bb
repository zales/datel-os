SUMMARY = "Universal Python binding for the LMDB 'Lightning' Database"
# Moonraker pins 1.4.1, whose setup.py needs distutils (gone in Python 3.12); 1.6.2 keeps the 1.x API.
HOMEPAGE = "https://github.com/jnwatson/py-lmdb"
LICENSE = "OLDAP-2.8"
LIC_FILES_CHKSUM = "file://LICENSE;md5=153d07ef052c4a37a8fac23bc6031972"

SRC_URI[sha256sum] = "d28e3fa59935ff688858760ec52f202ecb8c1089a3f68d1f162ea3078d151e73"

inherit pypi setuptools3

# Build the CPython extension against the bundled liblmdb.
export LMDB_FORCE_CPYTHON = "1"

RDEPENDS:${PN} += "python3-core"
