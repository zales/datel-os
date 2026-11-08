#!/bin/bash
# Build K1 OS in Docker. The build tree lives in the Docker volume "k1yocto-work"
# because Yocto needs a case-sensitive file system.
#
#   ./build.sh                 bitbake k1-image
#   ./build.sh virtual/kernel  any other bitbake target
#   JOBS=4 ./build.sh          bitbake threads and make jobs (default: host CPUs)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-k1-image}"
KAS_FILE="${KAS_FILE:-kas-creality-k1.yml}"

# bitbake threads and make jobs follow the host (the kas config only sets 8 as
# a default); --cpu-shares keeps the build behind other containers when they
# compete for the CPU, e.g. on the NAS that runs the release builds.
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"

docker volume create k1yocto-work >/dev/null
docker run --rm -u root --cpu-shares 512 -v k1yocto-work:/work -v "$HERE":/src:ro \
  -e TARGET="$TARGET" -e KAS_FILE="$KAS_FILE" -e JOBS="$JOBS" \
  --entrypoint bash ghcr.io/siemens/kas/kas:4.7 -c '
    # A fresh copy of the layer: files deleted in the source must not linger in the volume.
    rm -rf /work/k1-yocto/meta-creality-k1
    mkdir -p /work/k1-yocto/meta-creality-k1
    cp -r /src/meta-creality-k1/. /work/k1-yocto/meta-creality-k1/
    cp /src/kas-creality-k1*.yml /work/k1-yocto/
    chown -R builder:builder /work/k1-yocto
    su builder -c "cd /work/k1-yocto && KAS_WORK_DIR=/work/k1-yocto \
        BB_ENV_PASSTHROUGH_ADDITIONS=\"BB_NUMBER_THREADS PARALLEL_MAKE\" BB_NUMBER_THREADS=$JOBS PARALLEL_MAKE=\"-j $JOBS\" \
        kas shell $KAS_FILE -c \"bitbake $TARGET\"" \
      > /work/k1-yocto/build-last.log 2>&1
    rc=$?
    grep -a -E "^(ERROR|WARNING)|Tasks Summary" /work/k1-yocto/build-last.log | tail -20
    echo "bitbake exit: $rc"
    ls -la /work/k1-yocto/build/tmp/deploy/images/creality-k1/ | grep -E "\.img$|squashfs-xz$|xImage$" || true
    exit $rc'
