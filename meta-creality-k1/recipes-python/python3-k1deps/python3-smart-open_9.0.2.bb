SUMMARY = "Utils for streaming large files; required by streaming-form-data"
HOMEPAGE = "https://github.com/piskvorky/smart_open"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=c92d414d58f836a4ac403385238bc445"

PYPI_PACKAGE = "smart_open"
SRC_URI[sha256sum] = "adfe6413bfb39c2895cf9d066c8bea326aeb8b3b717306e6a10c9efa931ae796"

inherit pypi python_setuptools_build_meta

DEPENDS += "python3-setuptools-scm-native"

RDEPENDS:${PN} += "python3-wrapt python3-core python3-io"
