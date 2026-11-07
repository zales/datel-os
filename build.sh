#!/bin/bash
# Build K1 OS in Docker. The build tree lives in the Docker volume "k1yocto-work"
# because Yocto needs a case-sensitive file system.
#
#   ./build.sh                 bitbake k1-image
#   ./build.sh virtual/kernel  any other bitbake target
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-k1-image}"

docker volume create k1yocto-work >/dev/null
docker run --rm -u root -v k1yocto-work:/work -v "$HERE":/src:ro -e TARGET="$TARGET" \
  --entrypoint bash ghcr.io/siemens/kas/kas:4.7 -c '
    mkdir -p /work/k1-yocto/meta-creality-k1
    cp -r /src/meta-creality-k1/. /work/k1-yocto/meta-creality-k1/
    cp /src/kas-creality-k1.yml /work/k1-yocto/
    chown -R builder:builder /work/k1-yocto
    su builder -c "cd /work/k1-yocto && KAS_WORK_DIR=/work/k1-yocto kas shell kas-creality-k1.yml -c \"bitbake $TARGET\"" \
      > /work/k1-yocto/build-last.log 2>&1
    rc=$?
    grep -E "^(ERROR|WARNING)|Tasks Summary" /work/k1-yocto/build-last.log | tail -20
    echo "bitbake exit: $rc"
    ls -la /work/k1-yocto/build/tmp/deploy/images/creality-k1/ | grep -E "\.img$|squashfs-xz$|xImage$" || true
    exit $rc'
