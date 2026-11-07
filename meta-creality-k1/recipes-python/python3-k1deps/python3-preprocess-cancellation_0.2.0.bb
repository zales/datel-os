SUMMARY = "GCode processor that adds Klipper cancel-object markers"
HOMEPAGE = "https://github.com/kageurufu/cancelobject-preprocessor"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://LICENSE;md5=1ebbd3e34237af26da5dc08a4e440464"

PYPI_PACKAGE = "preprocess_cancellation"
SRC_URI[sha256sum] = "eb68494e35c0a1fe83716f2a14e12b3e1cdedf9458752be1cace00f944d90760"

# pyproject.toml has only [tool.poetry] metadata; the sdist's setup.py builds it.
inherit pypi setuptools3

RDEPENDS:${PN} += "python3-core"
