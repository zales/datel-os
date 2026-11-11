SUMMARY = "Zig compiler, the official binary release, for the build host"
DESCRIPTION = "Builds k1os-camera: its Zig sources, and through `zig cc` the C it links \
(mbedtls, k1os-stream). Zig brings its own musl and compiler runtime for the K1's ABI \
(MIPS32r2, 64-bit FPU, NaN 2008), so nothing of the Yocto toolchain is involved."
HOMEPAGE = "https://ziglang.org/"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=d934d7758eb646c9c6a2162d88427689"

ZIG_HOST = "${@{'aarch64': 'aarch64-linux', 'x86_64': 'x86_64-linux'}[d.getVar('BUILD_ARCH')]}"
SRC_URI = "https://ziglang.org/download/${PV}/zig-${ZIG_HOST}-${PV}.tar.xz;name=${ZIG_HOST}"
# from https://ziglang.org/download/index.json
SRC_URI[aarch64-linux.sha256sum] = "a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795"
SRC_URI[x86_64-linux.sha256sum] = "3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a"
S = "${WORKDIR}/zig-${ZIG_HOST}-${PV}"

inherit native

do_configure[noexec] = "1"
do_compile[noexec] = "1"

# The compiler finds its library at ../lib/zig from where it is.
do_install() {
    install -d ${D}${bindir} ${D}${libdir}/zig
    install -m 0755 ${S}/zig ${D}${bindir}/zig
    cp -R --no-dereference --preserve=mode,links ${S}/lib/. ${D}${libdir}/zig/
}

# a static binary and a tree of sources: nothing to strip or relocate
INHIBIT_SYSROOT_STRIP = "1"
