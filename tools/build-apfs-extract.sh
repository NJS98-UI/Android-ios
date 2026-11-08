#!/bin/bash
# Build apfs_extract (offline APFS -> pax tar with iOS decmpfs decompression).
#
#   tools/build-apfs-extract.sh [OUTDIR] [SRCDIR]
#
# OUTDIR defaults to $WORK/build (WORK=/tmp/ios-root-build), SRCDIR to
# $WORK/apfs-fuse. apfs-fuse (sgan81) is cloned with its lzfse submodule if
# absent, its three static libs are built with cmake/ninja, and
# tools/apfs_extract.cpp (in this repo) is linked against them. tools/
# build-ios-root.sh expects the resulting binary in OUTDIR/apfs_extract.
#
# Needs: git, cmake, ninja, g++, libarchive/zlib/bz2/openssl dev headers.
# apfs_extract.cpp is committed here; apfs-fuse is a third-party clone kept
# outside the repo. Network access is only needed for the first clone.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
: "${WORK:=/tmp/ios-root-build}"
out=${1:-$WORK/build}
src=${2:-$WORK/apfs-fuse}
url=https://github.com/sgan81/apfs-fuse.git

for t in git cmake ninja g++ pkg-config; do
    command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 2; }
done
for h in /usr/include/archive.h /usr/include/zlib.h /usr/include/bzlib.h; do
    [[ -f $h ]] || { echo "missing dev header: $h"; exit 2; }
done

mkdir -p "$out" "$(dirname "$src")"
if [[ ! -d $src/.git ]]; then
    echo "cloning apfs-fuse -> $src"
    git clone --depth 1 "$url" "$src"
    git -C "$src" submodule update --init --recursive --depth 1
else
    echo "reusing $src"
fi

build="$src/build-apfs-extract"
cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release
ninja -C "$build" apfs crypto lzfse

g++ -O2 -std=c++11 -I "$src" -I "$src/3rdparty/lzfse/src" \
    -o "$out/apfs_extract" "$repo/tools/apfs_extract.cpp" \
    "$build/libapfs.a" "$build/libcrypto.a" "$build/liblzfse.a" \
    -lz -lbz2 -lcrypto -larchive
chmod +x "$out/apfs_extract"
echo "built: $out/apfs_extract"
"$out/apfs_extract" 2>&1 | head -1 || true
