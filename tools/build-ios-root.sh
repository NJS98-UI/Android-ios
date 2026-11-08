#!/bin/bash
# Build ios16-root.simg for the OnePlus 12 (waffle) userdata partition.
#
#   tools/build-ios-root.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.simg [SIZE]
#
# SIZE defaults to 16G (must be >= the userdata partition's 4 KiB blocks need).
# This is the SWEET tools/mkiosroot.sh pipeline adapted to a Linux host with
# NO hfsplus.ko, NO /dev/fuse and NO /dev/kvm:
#
#   1. apfs-fuse's DecompressFile() exports each APFS dmg to a pax tar
#      (offline, no FUSE; 7zz cannot decode iOS decmpfs, libfsapfs cannot walk
#      these trees). SystemOS/AppOS get their /private/preboot/Cryptexes prefix.
#   2. tar -A concatenates the three archives into one raw image. libguestfs
#      attaches that tar as a virtio-blk disk; the appliance's GNU tar reads it
#      locally with `tar -xf /dev/sdb -C /hfs`. This avoids the 0.44 MB/s
#      virtio-serial bottleneck of `guestfish tar-in` (measured on this host).
#   3. SWEET additions (launchd/Setup/SpringBoard tweaks, logd stores, system
#      keybag, VirtualAudio removal) are built on the host into an overlay tar
#      because the libguestfs appliance has no python3. A post.sh inside that
#      same tar runs inside the appliance after extraction: it hard-links the
#      dyld shared cache and cryptex files to their root paths (those source
#      files only exist in the HFS+ volume at that point) and removes the
#      VirtualAudio plugin. GNU tar hard links and pax uid/gid/mode survive.
#   4. fsck.hfsplus rewrites the few localized non-ASCII names Linux decomposes
#      differently from Apple, then img2simg produces the fastboot sparse image.
#
# Apple artifacts are copyrighted and huge (OS.dmg 4.5 GiB, tars ~8 GiB,
# sparse image ~12 GiB): keep all of them OUT of git. This script needs ~40 GiB
# free in WORK and root privileges for chown/chmod/mount.
#
# Requirements: apfs-fuse's apfs_extract, libguestfs-tools (guestfish),
#   hfsprogs (mkfs.hfsplus, fsck.hfsplus), android-sdk-libsparse-utils
#   (img2simg), tar. libguestfs supermin needs a matching kernel/modules:
#     export SUPERMIN_KERNEL=/boot/vmlinuz-$(uname -r)
#     export SUPERMIN_MODULES=/lib/modules/$(uname -r)
#   and a populated modules.dep (`depmod $(uname -r)` on the shared host).
set -euo pipefail

[[ $# -ge 4 ]] || { sed -n '2,8p' "$0"; exit 2; }
os=$(realpath "$1") sysos=$(realpath "$2") appos=$(realpath "$3")
out=$(realpath -m "$4") size=${5:-16G}
repo=$(cd "$(dirname "$0")/.." && pwd)

for t in apfs_extract guestfish mkfs.hfsplus fsck.hfsplus img2simg tar python3; do
    command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 2; }
done
[[ -f $repo/tools/sweet-root-tweaks.py ]] || { echo "missing sweet-root-tweaks.py"; exit 2; }
[[ ! -e $out ]] || { echo "refusing to overwrite $out"; exit 1; }

: "${WORK:=/tmp/ios-root-build}"
mkdir -p "$WORK"
hfs="$WORK/root.img"
all="$WORK/all.tar"
overlay="$WORK/overlay.tar"

echo "== 1/4 export APFS volumes to pax tars =="
# apfs_extract DMG OUT.tar [--volume N] [--prefix P]. volume 0 is the single
# system volume of each of these three dmg images (verified: OS, SystemOS
# 'SydneyUpdate20H392.D22D221SystemCryptex', AppOS).
apfs_extract "$os"    "$WORK/os.tar"
apfs_extract "$sysos" "$WORK/sysos.tar" --prefix 'private/preboot/Cryptexes/OS/'
apfs_extract "$appos" "$WORK/appos.tar" --prefix 'private/preboot/Cryptexes/App/'
for t in os sysos appos; do
    [[ -s $WORK/$t.tar ]] || { echo "$t.tar empty"; exit 1; }
done
# tar -A keeps pax headers and hard links; ./ directory entries are harmless.
cp "$WORK/os.tar" "$all"
tar -Af "$all" "$WORK/sysos.tar" "$WORK/appos.tar"
echo "combined tar: $(du -h "$all" | cut -f1)"

echo "== 2/4 SWEET overlay (host-side tweaks + links) =="
stage="$WORK/stage"
rm -rf "$stage"; mkdir -p "$stage"
# Minimal tree for sweet-root-tweaks.py: it needs System/Library/xpc and
# writes preferences/containers under private/var. Extract just those paths
# from the combined tar so the Python stage has the real plists to patch.
mkdir -p "$stage/System/Library/xpc" "$stage/private/var/mobile/Library/Preferences" \
         "$stage/private/var/containers" \
         "$stage/System/Library/Frameworks/MediaToolbox.framework"
# HAL/* is deliberately NOT staged: the VirtualAudio move is done by post.sh
# inside the appliance (an overlay tar cannot delete the source from all.tar).
# tweaks.py audio() sees no VirtualAudio.plugin and skips that move cleanly.
tar -xf "$all" -C "$stage" --wildcards \
    'System/Library/xpc/launchd.plist' \
    'private/var/mobile/Library/Preferences/*' \
    'private/var/containers/*' \
    'System/Library/Frameworks/MediaToolbox.framework/*' 2>/dev/null || true
[[ -f $stage/System/Library/xpc/launchd.plist ]] || {
    echo "launchd.plist not found in tar (wrong OS.dmg?)"; exit 1; }
python3 "$repo/tools/sweet-root-tweaks.py" "$stage"

# VirtualAudio moves cannot be expressed by an overlay tar (the source file
# stays behind), and the dyld/cryptex hard links need their source files in the
# HFS+ volume. post.sh inside the overlay tar does both inside the appliance.
# The link list is generated at build time from the OS tar so no paths are
# guessed: XNU ignition_level=1 does not search the cryptexes.
python3 - "$all" "$stage/post.sh" <<'PY'
import sys, tarfile
all_tar, post = sys.argv[1], sys.argv[2]
names = []
with tarfile.open(all_tar) as t:
    for m in t:
        names.append((m.name.rstrip('/'), m.isdir(), m.issym(), m.islnk()))
root = set(n for n, d, s, h in names if not d)
cr = 'private/preboot/Cryptexes/'
dsc = cr + 'OS/System/Library/Caches/com.apple.dyld/'
lines = ['#!/bin/sh', 'set -e', 'cd /hfs']
# dyld shared cache at the root path dyld looks at ignition level 1.
lines.append('mkdir -p System/Library/Caches/com.apple.dyld')
for n, d, s, h in names:
    if n.startswith(dsc) and not d and not s and not h:
        b = n.rsplit('/', 1)[-1]
        lines.append(f'[ -e System/Library/Caches/com.apple.dyld/{b} ] || ln /hfs/"{n}" /hfs/System/Library/Caches/com.apple.dyld/"{b}" 2>/dev/null || true')
# every cryptex file with no root counterpart (libobjc-trampolines, libffi,
# libstdc++ ...); symlinks are copied, regular files hard-linked.
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
          'cd /; rm -f /hfs/post.sh; umount /hfs']
open(post, 'w').write('\n'.join(lines) + '\n')
PY
chmod 0755 "$stage/post.sh"
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
# GNU tar with --numeric-owner keeps the pax uid/gid/mode from the Python stage.
tar --format=pax --numeric-owner -cf "$overlay" -C "$stage" .
echo "overlay tar: $(du -h "$overlay" | cut -f1)"

echo "== 3/4 create HFS+ and inject both tars inside the appliance =="
[[ ! -e $hfs ]] || { echo "refusing to overwrite $hfs"; exit 1; }
truncate -s "$size" "$hfs"
mkfs.hfsplus -s -J -v iOSRoot "$hfs"
# Disk order: /dev/sda = HFS+ target, /dev/sdb = combined tar, /dev/sdc =
# overlay tar, /dev/sdd = appliance root. Verified on this host with the same
# libguestfs supermin appliance (TCG, no /dev/kvm): `tar -xf /dev/sdb -C /hfs`
# reads the tar locally, ~2 orders of magnitude faster than guestfish tar-in.
# The appliance needs modprobe hfsplus and a short mount retry; it has no
# python3, so post.sh (inside the overlay tar) does the links/moves/unmount.
export SUPERMIN_KERNEL=${SUPERMIN_KERNEL:-/boot/vmlinuz-$(uname -r)}
export SUPERMIN_MODULES=${SUPERMIN_MODULES:-/lib/modules/$(uname -r)}
cat > "$WORK/inject.gf" <<'CMDS'
run
debug sh "modprobe hfsplus 2>/dev/null || true; mkdir -p /hfs; i=0; until mount -t hfsplus -o force,rw /dev/sda /hfs 2>/dev/null; do i=\$((i+1)); [ \$i -ge 5 ] && { echo MOUNT_FAIL; exit 1; }; sleep 1; done; echo MOUNTED; tar -xf /dev/sdb -C /hfs; tar -xf /dev/sdc -C /hfs; sh /hfs/post.sh"
CMDS
guestfish -a "$hfs" -a "$all" -a "$overlay" < "$WORK/inject.gf"

echo "== 4/4 fsck + sparse image =="
# Linux hfsplus decomposes a few localized non-ASCII names differently; let
# fsck_hfs rewrite them, then verify a clean filesystem.
fsck.hfsplus -f -y "$hfs" | grep -v 'Illegal name' || true
fsck.hfsplus -f -n "$hfs"
img2simg "$hfs" "$out"
echo "$out: $(du -h "$out" | cut -f1)"
echo "verify with: simg2img $out /tmp/verify.img && fsck.hfsplus -f -n /tmp/verify.img"
