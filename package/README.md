# iOS 16 on OnePlus 12 (waffle, SM8650) - bring-up package

**`shim-boot-waffle.img` is a complete waffle boot image (boot.img v4, 16.7 MB)
wrapping the XNU userspace shim + an XNU kernel payload (`xnu/kernel.sweet`
built from `xnu-8796.141.3` + patches 0001-0080, macOS 15 / Xcode 16.4).**
This is the image to `fastboot boot` first.

What is in here
- `shim-boot-waffle.img` : boot.img v4 (header_version 4, 4096-byte pages,
  `console=null`), kernel at 0x8000, ramdisk at 0x1000000. Built with
  `DEVICE=waffle BOOTIMG_VER=4 shim/build.sh out/payload-waffle.bin` (run from
  `shim/`; the payload path is relative to `shim/`). The ramdisk is the XNU
  payload produced by `tools/mkpayload.py` from `xnu/kernel.sweet` +
  `waffle-test.adt`.
- `shim-image-waffle.bin` : the raw shim binary (what ABL jumps to at 0x8000).
  Kept for reference; the full image is `shim-boot-waffle.img`.

Hardware values confirmed from a real PJD110 ColorOS 16 `vendor_boot` DTB
- `PJD110_16.0.10.501(CN01)`, fetched via OPlus-Tracker + HTTP Range (only the
  `vendor_boot` operations were downloaded, hash-verified).
- GICD `0x17100000/0x10000`, GICR `0x17180000/0x200000`, `redistributor-stride
  0x40000`; IMEM `0x14680000/0x1000` (restart_reason@0x65c); timebase 19.2 MHz;
  EL1 virtual timer INTID 27; UFS `0x1d84000`; USB DWC3 `0xa600000`.
- The ADT's GIC `reg` reads `0x16100000` because it is relative to
  `arm-io` `ranges` (`SOC_BASE 0x01000000`); +`0x01000000` = `0x17100000`.

Framebuffer is discovered at runtime (not a fixed address)
- The stock C16 `vendor_boot` DTB has **no static framebuffer base**:
  `non_secure_display_region` has no `reg` and `memory { reg=<0 0 0 0>; }` is
  filled by ABL into the **live FDT** passed in x0 at boot.
- The payload therefore carries `fb_base=0` plus the geometry (1440x3168,
  stride 5760, 32 bpp). At boot the shim reads ABL's live FDT via
  `fdt_fb_probe()`, finds the splash reserved-memory region, and sets
  `con_fb_phys`; `loader_boot()` patches the waffle ADT's `sweet-fbcon/reg[0]`
  with the same base so the early fbcon console (`0003`) and AppleCLCD (`0046`)
  both use the real splash address. Sweet ADTs (non-zero reg) are untouched.
- No device was on hand: none of this is real-boot verified. A first boot with
  no ABL splash region can still show a blank console. Touch IC / keys / real
  rowBytes also need the live FDT.

Rebuild from source
```
python3 tools/mkadt.py waffle-test.adt --device waffle
python3 tools/mkpayload.py xnu/kernel.sweet waffle-test.adt shim/out/payload-waffle.bin \
    --fb-base 0 --fb-stride 5760 --fb-w 1440 --fb-h 3168 --fb-depth 32
cd shim && DEVICE=waffle BOOTIMG_VER=4 ./build.sh out/payload-waffle.bin
cp out/shim-boot.img ../package/shim-boot-waffle.img
cp out/Image ../package/shim-image-waffle.bin
```
If ABL's live splash address ever becomes known and needs a hard override,
pass `--fb-addr <phys>` to `mkadt.py` and `--fb-base <phys>` to `mkpayload.py`.
`--fb-stride 262144` in older docs was a stale workaround; use 5760 (1440*4).

Flash (unlocked bootloader; keep the Android partition backups intact)
    fastboot boot shim-boot-waffle.img      # one-shot, preserves Android
- iOS rootfs goes into the existing `userdata` partition (no GPT changes).
- Confirm each destructive step (e.g. userdata erase) with the user before running.

Verification already done
- Full xnu patch chain (0001-0080) applies cleanly to `xnu-8796.141.3`.
- Kernel built on GitHub Actions `macos-15` runner (Xcode 16.4, run
  42354678987) -> `xnu/kernel.sweet` (17,188,624 B).
- `shim/fdt.c` `reg` decoding fixed for SM8650 `/soc` 1/1 cell sizes; host-tested
  against C16 `dtb2`/`dtb3` and C14 `dtb0` (GIC/IMEM/stride) plus a synthetic
  splash DTB. Sweet objects compile with 0 absolute relocations.
- Sweet ADT remains byte-identical to HEAD (fixed seed); waffle's only delta is
  vtimer 19 -> 27.
- Payload v2 + boot.img v4 assembled locally with `aarch64-linux-gnu-gcc` 12;
  embedded payload verified `fb_base 0`, stride 5760, 1440x3168x32.
