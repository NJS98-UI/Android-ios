# iOS 16 on OnePlus 12 (waffle, SM8650) - bring-up package

**`shim-boot-waffle.img` is a complete, buildable waffle boot image (boot.img
v4, 16.7 MB) wrapping the XNU userspace shim + an XNU kernel payload
(`kernel.development.sweet` built from `xnu-8796.141.3` + patches 0001-0080,
macOS 15 / Xcode 16.4).** This is the image to `fastboot boot` first.

What is in here
- `shim-boot-waffle.img` : boot.img v4 (header_version 4, 4096-byte pages,
  `console=null`), kernel at 0x8000, ramdisk at 0x1000000. Built with
  `DEVICE=waffle BOOTIMG_VER=4 shim/build.sh shim/out/payload-waffle.bin`.
  The ramdisk is the XNU payload produced by `tools/mkpayload.py` from
  `xnu/kernel.sweet` + `waffle.adt`.
- `shim-image-waffle.bin` : the raw shim binary (what ABL jumps to at 0x8000).
  Kept for reference; the full image is `shim-boot-waffle.img`.

Known caveat on this image (must fix before real boot)
- **Framebuffer base is a placeholder (`0x9c000000`, sweet's address).** The
  waffle ABL's `cont_splash` address is not yet confirmed. On first boot the
  kernel will map a FB region that may not be the real one, so the console /
  iOS display may be blank or corrupted. Get the real address from a stock
  OnePlus 12 `vendor_boot` dtb (`/reserved-memory/cont_splash_base` reg) and
  rebuild:
    ```
    python3 tools/mkadt.py waffle.adt --device waffle --fb-addr <cont_splash_base>
    python3 tools/mkpayload.py xnu/kernel.sweet waffle.adt shim/out/payload-waffle.bin \
        --fb-base <cont_splash_base> --fb-stride 262144 --fb-w 1440 --fb-h 3168 --fb-depth 32
    DEVICE=waffle BOOTIMG_VER=4 shim/build.sh shim/out/payload-waffle.bin
    ```
- **Touch IC, keys, USB, IMEM offset** are also pending the real `vendor_boot`
  dtb. The shim discovers GIC / FB geometry at runtime from the live FDT;
  the touch controller identity (candidate Goodix/Samsung) needs the dtb to
  confirm.

Flash (unlocked bootloader, device must have the Android partition backups intact)
    fastboot boot shim-boot-waffle.img      # one-shot, preserves Android
- iOS rootfs goes into the existing `userdata` partition (no GPT changes).
- Confirm each destructive step (e.g. userdata erase) with the user before running.

Verification already done
- Full xnu patch chain (0001-0080) applies cleanly to `xnu-8796.141.3`.
- Kernel built on GitHub Actions `macos-15` runner (Xcode 16.4) -> `kernel.development.sweet` (17 MB).
- Payload generated; boot.img v4 assembled; `shim-boot-waffle.img` is 16.7 MB.
- `tools/mkadt.py --device waffle` emits GICD 0x17100000, GICR 0x17180000/0x200000,
  `redistributor-stride` 0x40000, CPU MPIDRs, board compat `oneplus,waffle` /
  `qcom,sm8650`; sweet output byte-identical.
- Shim compiles for waffle with `aarch64-linux-gnu-gcc` 12.
