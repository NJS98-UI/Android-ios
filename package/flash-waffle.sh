#!/bin/bash
# One-tap iOS 16 bring-up flash for OnePlus 12 (waffle / PJD110 / SM8650).
#
#   package/flash-waffle.sh
#
# Run from the repository root or from package/. Requires an unlocked
# bootloader and the two package artifacts next to this script:
#   shim-boot-waffle.img   boot.img v4 (shim + XNU payload, rd=ufsroot0)
#   ios16-root.simg        sparse HFS+ iOS root for the userdata partition
#
# ios16-root.simg is produced by tools/build-ios-root.sh (needs ~16 GiB free
# and the Apple IPSW; it is not committed because Apple's root is copyrighted
# and the sparse image is ~12 GiB). Keep bootloaders, recovery, modem, persist
# and the user's partition backups intact: this only touches userdata and
# boots a temporary image.
set -euo pipefail

cd "$(dirname "$0")"

boot=shim-boot-waffle.img
root=ios16-root.simg

command -v fastboot >/dev/null || { echo "fastboot not found (android-tools)"; exit 2; }
[[ -f $boot ]] || { echo "missing $boot"; exit 2; }
[[ -f $root ]] || {
    echo "missing $root"
    echo "build it first: tools/build-ios-root.sh OS.dmg SystemOS.dmg AppOS.dmg $root"
    exit 2
}

echo "Device (expect exactly one waffle in fastboot):"
fastboot devices || true
count=$(fastboot devices | grep -cw fastboot || true)
[[ $count -eq 1 ]] || { echo "expected 1 fastboot device, found $count"; exit 2; }

echo
echo "boot image : $boot"
echo "root image : $root ($(du -h "$root" | cut -f1))"
echo
echo "This ERASES the Android userdata partition and writes the iOS root into"
echo "it (no GPT changes). Android user data cannot be recovered afterwards."
echo "Bootloaders, recovery, modem, persist and backups are left untouched."
echo
read -r -p "Type ERASE to confirm flashing userdata: " answer
[[ $answer == ERASE ]] || { echo "cancelled"; exit 1; }

# Sparse flash: a raw 16 GiB image exhausts host RAM (earlyoom), img2simg keeps
# it bounded and FILL chunks overwrite every block a previous rw boot changed.
fastboot -S 512M flash userdata "$root"

# Qualcomm ABL often hangs in "Sending" right after a large flash. If the next
# fastboot boot stalls, re-enter fastboot by hand with Power + Volume down and
# re-run this script (it re-flashes) or boot the image directly. Do not unplug.
echo
echo "userdata flashed. Booting the shim (temporary; nothing written to boot):"
fastboot boot "$boot"

echo
echo "First boot takes several minutes on the Apple logo."
echo "To return to fastboot: hold Power + Volume down."
