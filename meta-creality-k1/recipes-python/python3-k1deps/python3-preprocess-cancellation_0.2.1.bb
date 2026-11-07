SUMMARY = "GCode processor that adds Klipper cancel-object markers"
HOMEPAGE = "https://github.com/kageurufu/cancelobject-preprocessor"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://LICENSE;md5=1ebbd3e34237af26da5dc08a4e440464"

PYPI_PACKAGE = "preprocess_cancellation"
SRC_URI[sha256sum] = "e2f1224e1ba1603bdfdbf6937caaf91082dc849e5122e80a5328aa999433ce79"

# pyproject.toml has only [tool.poetry] metadata; the sdist's setup.py builds it.
inherit pypi python_setuptools_build_meta

RDEPENDS:${PN} += "python3-core"

# PEP 639 license metadata (license = "SPDX", license-files = [...]) is newer
# than the setuptools in scarthgap; rewrite it to the form it understands.
do_configure:prepend() {
    sed -i -E -e 's/^license = "([^"]*)"$/license = {text = "\1"}/' \
              -e '/^license-files *=/d' ${S}/pyproject.toml
}
