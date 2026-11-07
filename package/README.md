# iOS 16 on OnePlus 12 (waffle, SM8650) - bring-up package

What is in here
- `shim-boot-waffle.img` : boot.img v4 (header_version 4, 4096-byte pages, `console=null`)
  wrapping the compiled XNU userspace shim + an empty newc cpio ramdisk. Built with
  `DEVICE=waffle BOOTIMG_VER=4 shim/build.sh`. This is the *shim* image; it is not
  yet a bootable iOS image because it carries no XNU kernel payload (see "what's
  missing" below).
- `shim-image-waffle.bin` : the raw shim binary (what ABL jumps to at 0x8000).

What is missing (the hard blockers)
1. **XNU kernel binary** (`.flat` / `kernel.sweet` for waffle). The kernel is built
   from `xnu-8796.141.3` + `xnu/patches/0001..0080`. The full patch chain was
   validated to apply cleanly on Linux (staging scripts + 0001-0079 + 0080). The
   build still needs a **macOS** host (`darwin-xnu-build`, Xcode 15.x `iig`), which
   GitHub-hosted runners did not provide on this account
   (`macos-14` -> "arm64-us-xl not supported"; `macos-13` -> queued/retired).
2. **Live waffle DTB / ABL splash address / touch IC / IMEM offset**. These come
   from a stock OnePlus 12 `vendor_boot` + `dtb`. The shim discovers the GIC and
   framebuffer at runtime from the live FDT, but the ABL splash framebuffer
   address and the touch controller identity are not yet confirmed.

How to finish (on a macOS host with Xcode 15.x)
1. Build the kernel:
       git clone --depth 1 <this repo> ios
       cd ios && cp xnu/patches/*.patch xnu/patches/*.sh <dxb>/patches/
       # darwin-xnu-build (blacktop/darwin-xnu-build) pinned in .github/workflows/xnu.yml
       MACHINE_CONFIG=SWEET bash <dxb>/build.sh   # xnu-8796.141.3, arm64
       # -> kernel.sweet (or kernel.development.arm64) in fakeroot/System/Library/Kernels
2. Build the waffle ADT (once the real splash fb address is known):
       python3 tools/mkadt.py waffle.adt --device waffle \
           --fb-addr <cont_splash_base> --fb-size 0x1200000 \
           --fb-w 1440 --fb-h 3168
3. Build the XNU payload from the kernel binary:
       python3 tools/mkpayload.py payload.bin \
           --kernel kernel.sweet --adt waffle.adt \
           --fb-addr <cont_splash_base> --fb-stride 0x40000 --fb-w 1440 --fb-h 3168 --fb-depth 32
4. Wrap in a v4 boot image (DTB supplied by ABL from vendor_boot, not embedded):
       DEVICE=waffle BOOTIMG_VER=4 shim/build.sh payload.bin
       # -> shim/out/shim-boot.img
5. Flash (unlocked bootloader, device must have the Android partition backups intact):
       fastboot boot shim/out/shim-boot.img      # one-shot, preserves Android
   - iOS rootfs goes into the existing `userdata` partition (no GPT changes).
   - Confirm each destructive step (e.g. userdata erase) with the user before running.

Shim-only smoke test (no kernel needed)
   fastboot boot shim-boot-waffle.img
   - Expect the shim to map the FB, probe GICD/GICR (0x17100000 / 0x17180000,
     stride 0x40000) and the IMEM base (0x14680000) from the live FDT, print the
     GICR stride, and (with DEVICE_WAFFLE) skip the fallback frame draw until a
     payload provides geometry.

Verification already done
- Full xnu patch chain (0001-0080) applies cleanly to `xnu-8796.141.3` (host gcc,
  staging scripts ran; libpthread stage needs macOS `xcrun` but does not affect
  0080's targets).
- `tools/mkadt.py --device waffle` emits GICD 0x17100000, GICR 0x17180000/0x200000,
  `redistributor-stride` 0x40000, CPU MPIDRs, and board compat `oneplus,waffle` /
  `qcom,sm8650`; sweet output is byte-identical to before (no stride property).
- Shim compiles for waffle with the aarch64 cross-compiler (this image is that build).
