#!/bin/bash
# Build the shim and wrap it in a boot.img v2/v4 that mirrors the stock header.
#   BOOTIMG_VER=2 (default)   sweet: v2 with embedded DTB
#   BOOTIMG_VER=4             oneplus,waffle: v4, DTB comes from vendor_boot/ABL
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
CC=aarch64-linux-gnu-gcc
OBJCOPY=aarch64-linux-gnu-objcopy
# DEVICE=waffle -> no fallback FB draw (probe-only), plus the waffle boot image defaults
DEVICE=${DEVICE:-sweet}
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
[ "$DEVICE" = waffle ] && CFLAGS="$CFLAGS -DDEVICE_WAFFLE" && BOOTIMG_VER=${BOOTIMG_VER:-4}
mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c adt.c loader.c ufs.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$(aarch64-linux-gnu-readelf -r out/shim.o out/console.o out/mmu.o out/fdt.o out/adt.o out/loader.o out/ufs.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/adt.o out/loader.o out/ufs.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
size=$(aarch64-linux-gnu-nm out/shim.elf | awk '$3=="_end"{print strtonum("0x"$1)}')
truncate -s "$size" out/Image
# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else an empty
# newc cpio (ABL dislikes a zero-size ramdisk on some builds) -> diagnostics.
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi
# Boot image: v2 with an embedded DTB for sweet; v4 (no dtb field; ABL supplies
# the live DTB from vendor_boot) for oneplus,waffle / SM8650.
# BOOTIMG_VER=v4 DEVICE=waffle ./build.sh payload
BOOTIMG_VER=${BOOTIMG_VER:-2}
MKBOOTIMG="python3 $SCRIPT_DIR/../tools/mkbootimg/mkbootimg.py"
if [ "$BOOTIMG_VER" = 4 ]; then
	$MKBOOTIMG --header_version 4 --kernel out/Image --ramdisk out/ramdisk.bin \
		--base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --pagesize 4096 \
		--os_version 17.0.0 --os_patch_level 2035-06 \
		--cmdline "console=null" -o out/shim-boot.img
else
	$MKBOOTIMG --header_version 2 --kernel out/Image --ramdisk out/ramdisk.bin \
		--dtb ../dtb/boot_unpacked/dtb --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --dtb_offset 0x1f00000 --pagesize 4096 \
		--os_version 17.0.0 --os_patch_level 2035-06 \
		--cmdline "console=null" -o out/shim-boot.img
fi
# Host render of the console layout.  Some filesystems (e.g. Android shared
# storage) mount noexec, so stage the test binary in a private temp dir.
HOST_TEST=$(mktemp "${TMPDIR:-/tmp}/shim-host_test.XXXXXX")
gcc -O1 -Wall -o "$HOST_TEST" console.c host_test.c && "$HOST_TEST"
rm -f "$HOST_TEST"
ls -l out/Image out/shim-boot.img
