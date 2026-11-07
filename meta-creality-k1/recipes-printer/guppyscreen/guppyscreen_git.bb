SUMMARY = "Guppy Screen: LVGL touch UI for Klipper, built for the Creality K1"
HOMEPAGE = "https://github.com/ballaswag/guppyscreen"
LICENSE = "GPL-3.0-only & MIT & BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=1ebbd3e34237af26da5dc08a4e440464"

# Submodules: lvgl, lv_drivers (MIT), libhv (BSD-3-Clause), spdlog (MIT);
# wpa_supplicant's client library is vendored (BSD).
SRC_URI = "gitsm://github.com/ballaswag/guppyscreen.git;protocol=https;branch=main \
           file://guppyscreen.service \
           file://guppyconfig.json \
          "
SRCREV = "07409cb031bbbfc57cd7817ba295e5385e3d5565"
PV = "0.0.26+git${SRCPV}"
S = "${WORKDIR}/git"

inherit systemd

SYSTEMD_SERVICE:${PN} = "guppyscreen.service"

do_patch:append() {
    bb.build.exec_func('guppyscreen_apply_patches', d)
}
guppyscreen_apply_patches() {
    cd ${S}/lv_drivers && patch -p1 --forward < ../patches/0001-lv_driver_fb_ioctls.patch || true
    cd ${S}/spdlog && patch -p1 --forward < ../patches/0002-spdlog_fmt_initializer_list.patch || true
    cd ${S}/lvgl && patch -p1 --forward < ../patches/0003-lvgl-dpi-text-scale.patch || true
    # K1 OS keeps its data below /usr/data/k1os
    sed -i 's|/usr/data/printer_data|/usr/data/k1os/printer_data|g' ${S}/src/config.cpp ${S}/src/main.cpp
}

do_compile() {
    cd ${S}
    oe_runmake -C wpa_supplicant/wpa_supplicant CC="${CC}" libwpa_client.a
    oe_runmake -C libhv CC="${CC}" CXX="${CXX}" libhv

    # spdlog as a static compiled library (the upstream Makefile drives cmake)
    mkdir -p spdlog/build
    for f in spdlog.cpp stdout_sinks.cpp color_sinks.cpp file_sinks.cpp async.cpp cfg.cpp bundled_fmtlib_format.cpp; do
        [ -f spdlog/src/$f ] || continue
        ${CXX} ${CXXFLAGS} -std=c++17 -DSPDLOG_COMPILED_LIB -Ispdlog/include -c spdlog/src/$f -o spdlog/build/${f%.cpp}.o
    done
    ${AR} rcs spdlog/build/libspdlog.a spdlog/build/*.o

    oe_runmake CROSS_COMPILE=${TARGET_PREFIX} CC="${CC}" CXX="${CXX}" \
        GUPPY_ROTATE=1 GUPPYSCREEN_VERSION="${PV}-k1os" \
        CFLAGS="${CFLAGS} -I. -MD -MP" \
        LDFLAGS="${LDFLAGS} -Llibhv/lib -Lspdlog/build -l:libhv.a -latomic -lpthread \
                 -Lwpa_supplicant/wpa_supplicant/ -l:libwpa_client.a -lstdc++fs -l:libspdlog.a"
}

do_install() {
    install -d ${D}${libexecdir}/guppyscreen ${D}${datadir}/guppyscreen ${D}${sysconfdir}/k1os
    install -m 0755 ${S}/build/bin/guppyscreen ${D}${libexecdir}/guppyscreen/guppyscreen
    # GuppyScreen reads and rewrites guppyconfig.json next to its binary;
    # the root is read-only, so that file lives on /usr/data.
    ln -sf /usr/data/k1os/guppyscreen/guppyconfig.json ${D}${libexecdir}/guppyscreen/guppyconfig.json
    cp -R --no-preserve=ownership ${S}/themes ${D}${datadir}/guppyscreen/
    # Klipper helpers and macros GuppyScreen can use (opt-in from printer.cfg)
    install -d ${D}${datadir}/guppyscreen/klipper-extras
    install -m 0644 ${S}/k1/k1_mods/guppy_module_loader.py ${S}/k1/k1_mods/guppy_config_helper.py \
        ${S}/k1/k1_mods/tmcstatus.py ${S}/k1/k1_mods/calibrate_shaper_config.py \
        ${D}${datadir}/guppyscreen/klipper-extras/
    install -m 0644 ${S}/k1/scripts/guppy_cmd.cfg ${D}${datadir}/guppyscreen/
    install -m 0644 ${WORKDIR}/guppyconfig.json ${D}${sysconfdir}/k1os/guppyconfig.json

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/guppyscreen.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${libexecdir}/guppyscreen ${datadir}/guppyscreen ${systemd_system_unitdir}"
RDEPENDS:${PN} += "k1os-base"
