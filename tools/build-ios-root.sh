#!/bin/bash
# Build ios16-root.simg for the OnePlus 12 (waffle) userdata partition.
#
#   tools/build-ios-root.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.simg [SIZE]
#   tools/build-ios-root.sh --fetch-ipsw IPSW_URL OUT.simg [SIZE]   (fetch dmgs too)
#
# apfs_extract is built automatically (tools/build-apfs-extract.sh) when it is
# not on PATH. SIZE defaults to 16G (must cover the userdata partition's used
# blocks).
# This is the SWEET tools/mkiosroot.sh pipeline adapted to a Linux host with
# NO hfsplus.ko, NO /dev/fuse and NO /dev/kvm:
#
#   1. apfs-fuse's DecompressFile() exports each APFS dmg to its OWN pax tar
#      (offline, no FUSE; 7zz cannot decode iOS decmpfs, libfsapfs cannot walk
#      these trees). SystemOS/AppOS get their /private/preboot/Cryptexes prefix.
#      Keeping them separate avoids copying/concatenating a ~12 GiB os.tar.
#   2. libguestfs attaches all four tars as virtio-blk disks; the appliance's
#      GNU tar extracts them locally (`tar -xf /dev/sdb -C /hfs` ... /dev/sde).
#      This avoids the 0.44 MB/s virtio-serial bottleneck of `guestfish tar-in`
#      (measured on this host). Five-disk layout verified: sda=HFS+, sdb=os,
#      sdc=sysos, sdd=appos, sde=overlay, sdf=appliance root.
#   3. SWEET additions (launchd/Setup/SpringBoard tweaks, logd stores, system
#      keybag, VirtualAudio removal) are built on the host into an overlay tar
#      because the appliance has no python3. A generated post.sh inside that
#      tar runs inside the appliance after extraction: it hard-links the dyld
#      shared cache and cryptex files to their root paths (those sources only
#      exist in the HFS+ volume at that point) and removes VirtualAudio.plugin.
#   4. fsck.hfsplus rewrites the few localized non-ASCII names Linux decomposes
#      differently from Apple, then img2simg produces the fastboot sparse image.
#
# Apple artifacts are copyrighted and huge (OS.dmg 4.5 GiB, tars ~15 GiB,
# sparse image ~12 GiB): keep all of them OUT of git. Peak disk ~35-40 GiB:
# IPSW (7) + tars (15) + HFS raw while injecting (12) + simg (11), with the
# tars/raw deleted as soon as each stage finishes. Requires root.
#
# Requirements: git/cmake/ninja/g++ + libarchive/zlib/bz2/openssl dev headers
#   (to build apfs_extract once), libguestfs-tools (guestfish), hfsprogs
#   (mkfs.hfsplus, fsck.hfsplus), android-sdk-libsparse-utils (img2simg), tar,
#   python3. libguestfs supermin needs a matching kernel/modules and a
#   populated modules.dep:
#     export SUPERMIN_KERNEL=/boot/vmlinuz-$(uname -r)
#     export SUPERMIN_MODULES=/lib/modules/$(uname -r)
#     depmod $(uname -r)      # on a shared-kernel host
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
: "${WORK:=/tmp/ios-root-build}"
mkdir -p "$WORK"

# --fetch-ipsw: download just the three dmgs from the IPSW with HTTP Range,
# then continue with the normal build. Resume is handled by remotezip.py.
if [[ ${1:-} == --fetch-ipsw ]]; then
    [[ $# -ge 3 ]] || { sed -n '2,10p' "$0"; exit 2; }
    url=$2 outarg=$3 sizearg=${4:-16G}
    "$repo/tools/remotezip.py" "$url" '087-86698-044.dmg' "$WORK"
    "$repo/tools/remotezip.py" "$url" '087-86593-047.dmg' "$WORK"
    "$repo/tools/remotezip.py" "$url" '087-86715-047.dmg' "$WORK"
    mv "$WORK/087-86698-044.dmg" "$WORK/OS.dmg"
    mv "$WORK/087-86593-047.dmg" "$WORK/SystemOS.dmg"
    mv "$WORK/087-86715-047.dmg" "$WORK/AppOS.dmg"
    set -- "$WORK/OS.dmg" "$WORK/SystemOS.dmg" "$WORK/AppOS.dmg" "$outarg" "$sizearg"
fi

[[ $# -ge 4 ]] || { sed -n '2,10p' "$0"; exit 2; }
os=$(realpath "$1") sysos=$(realpath "$2") appos=$(realpath "$3")
out=$(realpath -m "$4") size=${5:-16G}

for t in guestfish mkfs.hfsplus fsck.hfsplus img2simg tar python3; do
    command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 2; }
done
[[ -f $repo/tools/sweet-root-tweaks.py ]] || { echo "missing sweet-root-tweaks.py"; exit 2; }
[[ ! -e $out ]] || { echo "refusing to overwrite $out"; exit 1; }

# apfs_extract is not a distro package: build it from the committed source +
# a third-party apfs-fuse clone when it is not already on PATH.
if command -v apfs_extract >/dev/null; then
    APFS_EXTRACT=$(command -v apfs_extract)
elif [[ -x $WORK/build/apfs_extract ]]; then
    APFS_EXTRACT=$WORK/build/apfs_extract
else
    echo "== 0/4 build apfs_extract =="
    "$repo/tools/build-apfs-extract.sh" "$WORK/build" "$WORK/apfs-fuse"
    APFS_EXTRACT=$WORK/build/apfs_extract
fi

hfs="$WORK/root.img"
ostar="$WORK/os.tar" systar="$WORK/sysos.tar" apptar="$WORK/appos.tar"
overlay="$WORK/overlay.tar"

echo "== 1/4 export APFS volumes to pax tars =="
# apfs_extract DMG OUT.tar [--volume N] [--prefix P]. volume 0 is the single
# system volume of each dmg (verified: OS 'SydneyUpdate20H392.D22D221OS',
# SystemOS '...SystemCryptex', AppOS). OS.dmg is UDIF+lzfse; SystemOS/AppOS
# are raw APFS. apfs_extract opens all three directly.
"$APFS_EXTRACT" "$os"    "$ostar"
"$APFS_EXTRACT" "$sysos" "$systar" --prefix 'private/preboot/Cryptexes/OS/'
"$APFS_EXTRACT" "$appos" "$apptar" --prefix 'private/preboot/Cryptexes/App/'
for t in "$ostar" "$systar" "$apptar"; do
    [[ -s $t ]] || { echo "$t empty"; exit 1; }
done
ls -lh "$ostar" "$systar" "$apptar"

echo "== 2/4 SWEET overlay (host-side tweaks + links) =="
stage="$WORK/stage"
rm -rf "$stage"; mkdir -p "$stage"
# launchd.plist / preferences / containers / MediaToolbox all live in the OS
# volume; extract just those from os.tar so the Python stage patches real
# plists. HAL/* is deliberately NOT staged: the VirtualAudio move is done by
# post.sh inside the appliance (an overlay tar cannot delete a source file).
mkdir -p "$stage/System/Library/xpc" "$stage/private/var/mobile/Library/Preferences" \
         "$stage/private/var/containers" \
         "$stage/System/Library/Frameworks/MediaToolbox.framework"
tar -xf "$ostar" -C "$stage" --wildcards \
    'System/Library/xpc/launchd.plist' \
    'private/var/mobile/Library/Preferences/*' \
    'private/var/containers/*' \
    'System/Library/Frameworks/MediaToolbox.framework/*' 2>/dev/null || true
[[ -f $stage/System/Library/xpc/launchd.plist ]] || {
    echo "launchd.plist not found in os.tar (wrong OS.dmg?)"; exit 1; }
python3 "$repo/tools/sweet-root-tweaks.py" "$stage"

# post.sh hard-links the dyld shared cache and cryptex files to their root
# paths (XNU ignition_level=1 does not search cryptexes) and moves
# VirtualAudio.plugin. Its link list is generated from the three tar member
# name sets, so no paths are guessed. It runs inside the appliance where all
# source files are already in /hfs.
python3 - "$ostar" "$systar" "$apptar" "$stage/post.sh" <<'PY'
import sys, tarfile
tars, post = sys.argv[1:-1], sys.argv[-1]
names = []
for tp in tars:
    with tarfile.open(tp) as t:
        for m in t:
            names.append((m.name.rstrip('/'), m.isdir(), m.issym(), m.islnk()))
root = set(n for n, d, s, h in names if not d)
cr = 'private/preboot/Cryptexes/'
dsc = cr + 'OS/System/Library/Caches/com.apple.dyld/'
lines = ['#!/bin/sh', 'set -e', 'cd /hfs',
         'mkdir -p System/Library/Caches/com.apple.dyld']
for n, d, s, h in names:
    if n.startswith(dsc) and not d and not s and not h:
        b = n.rsplit('/', 1)[-1]
        lines.append(f'[ -e /hfs/System/Library/Caches/com.apple.dyld/{b} ] || ln /hfs/"{n}" /hfs/System/Library/Caches/com.apple.dyld/"{b}" 2>/dev/null || true')
for c in ('OS', 'App'):
    pref = cr + c + '/'
    for n, d, s, h in names:
        if not n.startswith(pref) or d or n.startswith(dsc):
            continue
        rel = n[len(pref):]
        if not rel or rel in root or rel.startswith('System/Library/Caches/com.apple.dyld/'):
            continue
        lines.append(f'mkdir -p /hfs/"$(dirname "{rel}")" 2>/dev/null || true')
        if s:
            lines.append(f'[ -e /hfs/"{rel}" ] || [ -L /hfs/"{rel}" ] || cp -P /hfs/"{n}" /hfs/"{rel}"')
        else:
            lines.append(f'[ -e /hfs/"{rel}" ] || [ -L /hfs/"{rel}" ] || ln /hfs/"{n}" /hfs/"{rel}" 2>/dev/null || true')
lines += ['mkdir -p /hfs/Library/Audio/Plug-Ins/HAL.disabled',
          '[ -e /hfs/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin ] && mv -f /hfs/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin /hfs/Library/Audio/Plug-Ins/HAL.disabled/ || true',
          'cd /']
open(post, 'w').write('\n'.join(lines) + '\n')
PY
chmod 0755 "$stage/post.sh"
sh -n "$stage/post.sh"

# logd stores (owner _logd 272) and the plain-plist system keybag.
db="$stage/private/var/db"
mkdir -p "$db/diagnostics/timesync" "$db/uuidtext" "$stage/private/var/keybags"
for d in diagnostics uuidtext diagnostics/timesync; do
    : > "$db/$d/.migrated"; chown 272:272 "$db/$d/.migrated"; chmod 0644 "$db/$d/.migrated"
done
chown -R 272:272 "$db/diagnostics" "$db/uuidtext"
chmod 0751 "$db/diagnostics"; chmod 0755 "$db/uuidtext" "$db/diagnostics/timesync"
cat > "$stage/private/var/keybags/systembag.kb" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>
PLIST
chmod 0700 "$stage/private/var/keybags"; chown 0:0 "$stage/private/var/keybags/systembag.kb"
chmod 0600 "$stage/private/var/keybags/systembag.kb"
tar --format=pax --numeric-owner -cf "$overlay" -C "$stage" .

echo "== 3/4 create HFS+ and inject the four tars inside the appliance =="
[[ ! -e $hfs ]] || { echo "refusing to overwrite $hfs"; exit 1; }
truncate -s "$size" "$hfs"
mkfs.hfsplus -s -J -v iOSRoot "$hfs"
# The appliance needs modprobe hfsplus and a short mount retry; it has no
# python3, so post.sh (inside the overlay tar) does the links/moves/unmount.
export SUPERMIN_KERNEL=${SUPERMIN_KERNEL:-/boot/vmlinuz-$(uname -r)}
export SUPERMIN_MODULES=${SUPERMIN_MODULES:-/lib/modules/$(uname -r)}
cat > "$WORK/inject.gf" <<'CMDS'
run
debug sh "modprobe hfsplus 2>/dev/null || true; mkdir -p /hfs; i=0; until mount -t hfsplus -o force,rw /dev/sda /hfs 2>/dev/null; do i=\$((i+1)); [ \$i -ge 5 ] && { echo MOUNT_FAIL; exit 1; }; sleep 1; done; echo MOUNTED; tar -xf /dev/sdb -C /hfs; tar -xf /dev/sdc -C /hfs; tar -xf /dev/sdd -C /hfs; tar -xf /dev/sde -C /hfs; cp /hfs/post.sh /post.sh; rm -f /hfs/post.sh; sh /post.sh; umount /hfs || { echo UMOUNT_FAIL; exit 1; }; echo UMOUNT_OK"
CMDS
guestfish -a "$hfs" -a "$ostar" -a "$systar" -a "$apptar" -a "$overlay" < "$WORK/inject.gf"
# The tars are no longer needed once the HFS volume is populated.
rm -f "$ostar" "$systar" "$apptar" "$overlay"

echo "== 4/4 fsck + sparse image =="
# Linux hfsplus decomposes a few localized non-ASCII names differently; let
# fsck_hfs rewrite them, then verify a clean filesystem.
fsck.hfsplus -f -y "$hfs" | grep -v 'Illegal name' || true
fsck.hfsplus -f -n "$hfs"
img2simg "$hfs" "$out"
echo "$out: $(du -h "$out" | cut -f1)"
echo "verify with: simg2img $out /tmp/verify.img && fsck.hfsplus -f -n /tmp/verify.img"
echo "the raw $hfs can be deleted after img2simg succeeds"
