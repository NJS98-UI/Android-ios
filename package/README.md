# iOS 16 on OnePlus 12 (waffle, SM8650) - bring-up package

A complete flashable bring-up set has **two** artifacts plus a script:

| File | What it is | Where it goes |
|------|-----------|---------------|
| `shim-boot-waffle.img` | boot.img v4: shim + XNU payload (`rd=ufsroot0`) | `fastboot boot` (temporary, boot partitions untouched) |
| `ios16-root.simg` | sparse case-sensitive HFS+ iOS 16 root | `fastboot -S 512M flash userdata` |
| `flash-waffle.sh` | interactive one-tap flash of both | run on the host |
| `shim-image-waffle.bin` | raw shim binary (reference only) | n/a |

`ios16-root.simg` is **not committed**: Apple's root is copyrighted and the
sparse image is ~12 GiB. Build it with `tools/build-ios-root.sh` from the
iPhone10,3 `16.7.16 (20H392)` IPSW (see below). Until it exists,
`flash-waffle.sh` refuses to run and `shim-boot-waffle.img` alone stops at
"cannot mount root" — a boot image is not a complete iOS system.

## Boot image (verified locally)

`shim-boot-waffle.img` (16,785,408 B, sha256
`374cb7f26be0079c9091da2c31c8d851f6fd3c3b879cdb9dc221972c5d513ea4`) wraps
`xnu/kernel.sweet` (xnu-8796.141.3 + patches 0001-0080) in a payload v2:

- v4 header: `header_version 4`, `header_size 1584`, `kernel_size 184320`,
  `ramdisk_size 16596064`; file offsets `kernel 0x1000`, `ramdisk 0x2e000`
  (the load addresses in `mkbootimg` are `0x8000` / `0x1000000`).
- payload cmdline: `debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam
  -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1
  wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1
  sweetfb_noconsole=1 sweetfb_hz=30`
- embedded ADT `waffle-test.adt` (12,632 B) is byte-identical to the tracked
  file and carries the real D22AP `/product` (63 properties) from the IPSW,
  which iOS identity/MobileGestalt needs.
- fb geometry `0x0 / 5760 / 1440x3168 / 32bpp`: base 0 means runtime discovery
  from ABL's live FDT (see below).

## Hardware values (real PJD110 ColorOS 16 `vendor_boot` DTB)

`PJD110_16.0.10.501(CN01)`, fetched via OPlus-Tracker + HTTP Range (only the
`vendor_boot` operations, hash-verified). GICD `0x17100000/0x10000`, GICR
`0x17180000/0x200000`, `redistributor-stride 0x40000`; IMEM
`0x14680000/0x1000` (`restart_reason@0x65c`); timebase 19.2 MHz; EL1 virtual
timer INTID 27; UFS `0x1d84000`; USB DWC3 `0xa600000`. The ADT's GIC `reg`
reads `0x16100000` because it is relative to `arm-io` `ranges`
(`SOC_BASE 0x01000000`); +`0x01000000` = `0x17100000`.

The static C16 DTB has **no framebuffer base** (`non_secure_display_region`
has no `reg`, `memory { reg=<0 0 0 0>; }` is filled by ABL into the live FDT
in x0). At boot `shim/fdt.c` `fdt_fb_probe()` finds the splash reserved-memory
region, `shim/adt.c` `adt_set_fb()` patches only `sweet-fbcon/reg[0]` when it
is 0 (waffle), and `loader_boot()` fills `boot_args.Video`. Sweet ADTs (non-zero
reg) stay byte-identical. `shim/fdt.c` decodes `reg` with each parent's real
`#address-cells/#size-cells` — SM8650 `/soc` is 1/1 and the old length-based
guess corrupted the GIC address. Host-tested against C16 `dtb2`/`dtb3`, C14
`dtb0`, and a synthetic splash DTB.

## Build the iOS root (`tools/build-ios-root.sh`)

```
tools/build-ios-root.sh OS.dmg SystemOS.dmg AppOS.dmg package/ios16-root.simg
```

Inputs come from
`iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw` (ipsw.me; use
`tools/remotezip.py` to fetch only the three dmgs + `d22ap.im4p`). The script
needs apfs-fuse's `apfs_extract`, guestfish, hfsprogs, img2simg, ~35-40 GiB
free and root. Pipeline: APFS dmg -> one pax tar each with decmpfs
decompression (7zz and libfsapfs cannot do this) -> all four tars attached as
virtio-blk disks, extracted locally inside the libguestfs appliance
(`tar -xf /dev/sdb` ... `/dev/sde`, measured ~100x faster than
`guestfish tar-in` here) -> host-built overlay with `sweet-root-tweaks.py` ->
in-appliance `post.sh` for dyld/cryptex hard links and VirtualAudio removal ->
clean `umount` -> `fsck.hfsplus -y` -> `img2simg`. Linux hfsplus decomposes a
few localized names differently; fsck rewrites them. The five-disk layout and
clean unmount were verified end-to-end on small samples.

Keep the dmgs, tars, raw HFS+ image and `ios16-root.simg` out of git. The
`research/` tree (including `d22ap.adt`) is already gitignored.

## Flash (unlocked bootloader; Android userdata will be erased)

```
package/flash-waffle.sh
```

It verifies exactly one fastboot device, asks you to type `ERASE`, runs
`fastboot -S 512M flash userdata ios16-root.simg` (no GPT changes; bootloaders,
recovery, modem, persist and backups are untouched), then
`fastboot boot shim-boot-waffle.img`. First boot takes several minutes on the
Apple logo. Qualcomm ABL often hangs in "Sending" after a large flash; re-enter
fastboot with Power + Volume down if a command stalls. Never unplug mid-flash.

## Rebuild the boot image from source

```
python3 tools/mkadt.py waffle-test.adt --device waffle
python3 tools/mkpayload.py xnu/kernel.sweet waffle-test.adt shim/out/payload-waffle.bin \
    --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30' \
    --fb-base 0 --fb-stride 5760 --fb-w 1440 --fb-h 3168 --fb-depth 32
cd shim && DEVICE=waffle BOOTIMG_VER=4 ./build.sh out/payload-waffle.bin
cp out/shim-boot.img ../package/shim-boot-waffle.img
cp out/Image ../package/shim-image-waffle.bin
```

`mkadt.py` needs `research/ipsw-x/d22ap.adt` (extract `d22ap.im4p` with pyimg4)
for `/product`. `--fb-stride 262144` in older docs was a stale workaround;
use 5760 (1440*4). If ABL's live splash address becomes known, pass
`--fb-addr <phys>` to `mkadt.py` and `--fb-base <phys>` to `mkpayload.py`.

## Verification status

- Full XNU patch chain applies to xnu-8796.141.3; kernel built on GitHub
  Actions `macos-15` (Xcode 16.4, run 42354678987).
- Boot.img v4 parsed locally: payload v2, root cmdline, fb geometry, embedded
  12,632 B `/product` ADT all byte-verified; fixed-seed sweet ADT generation is
  deterministic and the waffle-only profile deltas are unchanged. Both device
  profiles gain `/product` whenever `research/ipsw-x/d22ap.adt` is present
  (it is gitignored; generate it from the IPSW as described above).
- Root pipeline primitives verified on this host: three-dmg IPSW download
  (`ALL DOWNLOADS COMPLETE`, CRC-32 ok), SystemOS APFS->tar export
  (1459 files, 1280 decompressed, 0 errors), five-disk raw-tar injection,
  overlay, dyld/cryptex hard links, symlinks, uid/gid/mode, VirtualAudio move,
  clean `umount`, `fsck.hfsplus -y/-n`, `img2simg`, and a 2881-line generated
  `post.sh` from the real SystemOS tar. The full 16 GiB root was **not**
  assembled here (this sandbox has 20 GiB total, no KVM, no hfsplus.ko).
- No device was on hand: nothing here is real-boot verified. Splash FB phys,
  real panel rowBytes, touch IC/IRQ and gpio-keys still need the live FDT; a
  first boot with no ABL splash region can show a blank console.
