#!/bin/sh
# Builds k1os-camera for the Creality K1 (Ingenic X2000: MIPS32r2, 64-bit FPU,
# NaN 2008) with nothing but Zig; mbedtls, the shim in front of it (dtls.c)
# and k1os-stream go through `zig cc`.
# Static against musl: Zig's glibc headers have no stubs file for the NaN 2008
# ABI (gnu/stubs-o32_hard_2008.h), so C sources do not compile against them.
#
#   MBEDTLS=<mbedtls 3.6 release tree> K1OS_STREAM=<directory of k1os-stream.c> ./build.sh
#
# The unit tests run on the build machine: zig test main.zig
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
: "${MBEDTLS:?}" "${K1OS_STREAM:?}"
B=$HERE/build
TARGET="-target mipsel-linux-musleabihf -mcpu=mips32r2+fp64+nan2008"
CC="zig cc $TARGET -Os -ffunction-sections -fdata-sections"
# cfg/mbedtls_user.h turns on the SRTP extension of DTLS
MBED="-I$MBEDTLS/include -I$HERE/cfg -DMBEDTLS_USER_CONFIG_FILE=\"mbedtls_user.h\""
rm -rf "$B"; mkdir -p "$B/mbedtls"

for f in "$MBEDTLS"/library/*.c; do
    $CC -w $MBED -I"$MBEDTLS/library" -c "$f" -o "$B/mbedtls/$(basename "$f" .c).o" &
done; wait
$CC -Wall -Wextra $MBED -c "$HERE/dtls.c" -o "$B/dtls.o"

# the camera, overlay and hardware codec part: k1os-stream as a library
for f in k1os-stream helix overlay moonraker graph sysstat; do
    $CC -O2 -Wall -Wextra -std=gnu11 -DK1OS_STREAM_LIBRARY -c "$K1OS_STREAM/$f.c" -o "$B/stream-$f.o" &
done; wait

cd "$HERE"
zig build-exe main.zig "$B/dtls.o" "$B"/stream-*.o "$B"/mbedtls/*.o $TARGET -lc -O ReleaseFast -fstrip --gc-sections -femit-bin="$B/k1os-camera"
# the timelapse's MP4 writer, a program of its own
zig build-exe h264-to-mp4.zig $TARGET -lc -O ReleaseSafe -fstrip -femit-bin="$B/h264-to-mp4"
ls -la "$B/k1os-camera" "$B/h264-to-mp4"
