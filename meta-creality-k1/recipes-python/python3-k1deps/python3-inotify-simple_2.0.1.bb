SUMMARY = "A simple wrapper around inotify"
HOMEPAGE = "https://github.com/chrisjbillington/inotify_simple"
LICENSE = "BSD-2-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=28a8c10291bba0bc0f8b9d5e87c0d826"

PYPI_PACKAGE = "inotify_simple"
SRC_URI[sha256sum] = "f010bbbd8283bd71a9f4eb2de94765804ede24bd47320b0e6ef4136e541cdc2c"

inherit pypi python_setuptools_build_meta

RDEPENDS:${PN} += "python3-core python3-ctypes python3-io"

# PEP 639 license metadata (license = "SPDX", license-files = [...]) is newer
# than the setuptools in scarthgap; rewrite it to the form it understands.
do_configure:prepend() {
    sed -i -E -e 's/^license = "([^"]*)"$/license = {text = "\1"}/' \
              -e '/^license-files *=/d' ${S}/pyproject.toml
}
