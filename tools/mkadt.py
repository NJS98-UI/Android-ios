#!/usr/bin/env python3
"""Build the minimal Apple Device Tree that the SWEET xnu needs to boot.

Only what the early boot path actually reads (see NOTES.md); every MMIO
address comes from the device's live FDT. Usage:
  mkadt.py OUT.adt [--dump] [--qemu] [--highmem] [--device sweet|waffle]
                   [--fb-addr A --fb-w W --fb-h H --fb-stride S]
                   [--phys-base P --mem-size M]
"""
import argparse, hashlib, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402

# /arm-io children are relative to this; it must not be 0 (serial_init bails).
SOC_BASE = 0x01000000
SWEET_ECID = 0x5357454554000001  # 'SWEET' + 1, synthetic
BOOT_MANIFEST_HASH = hashlib.sha384(b'sweet boot manifest').digest()

# QEMU virt (-M virt,gic-version=3 -cpu cortex-a76)
QEMU_GICD, QEMU_GICR, QEMU_TIMEBASE = 0x08000000, 0x080a0000, 62500000
QEMU_VTIMER_INTID = 27

PROFILES = {
    'sweet': dict(
        # Redmi Note 10 Pro (SM7150). physmap: above every Qualcomm XPU carve-out.
        phys_base=0xb0000000, mem_size=0x4d000000,
        high_phys_base=0x100000000, high_mem_size=0xfcc00000,
        gicd=0x17a00000, gicd_size=0x10000,
        gicr=0x17a60000, gicr_size=0x100000, gicr_stride=None,
        fb=0x9c000000, fb_size=0x1700000, fb_w=1080, fb_h=2400, fb_stride=1080 * 4,
        ufs=0x01d84000, ufs_size=0x3000,
        timebase=19200000, vtimer=19,
        # MPIDR Aff1 = core index (sweet: 0-5 A55, 6-7 A76).
        cores=[dict(mpidr=i << 8, mhz=1804 if i < 6 else 2304) for i in range(8)],
        compat=(b'xiaomi,sweet', b'qcom,sm7150'),
    ),
    'waffle': dict(
        # OnePlus 12 (SM8650). Bring-up defaults: phys_base 0x100000000 is above
        # all reserved-memory regions in upstream sm8650.dtsi (all <= 0xffe00000);
        # mem_size 0xC0000000 (3 GiB) is conservative - downstream Android DTBs
        # may add upper-bank carve-outs, verify from the live FDT and override
        # with --phys-base/--mem-size. Splash FB address unknown until on-device:
        # read /reserved-memory/cont_splash_mem from the stock DTB and pass
        # --fb-addr (and confirm w/h/stride). Panel: 1440x3168 (BOE Q9+ LTPO).
        phys_base=0x100000000, mem_size=0xC0000000,
        high_phys_base=0x100000000, high_mem_size=0xC0000000,
        gicd=0x17100000, gicd_size=0x10000,
        gicr=0x17180000, gicr_size=0x200000, gicr_stride=0x40000,
        fb=0x0, fb_size=0x1200000, fb_w=1440, fb_h=3168, fb_stride=1440 * 4,
        ufs=0x01d84000, ufs_size=0x3000,  # ufshc@1d84000, same JEDEC host base
        # arm,armv8-timer PPIs 13/14/11/12 in the C16 PJD110 DTB: the EL1
        # virtual timer is PPI 11 -> INTID 27 (sweet/SM7150 is the odd 19).
        timebase=19200000, vtimer=27,
        # MPIDR Aff1 = core index (sm8650.dtsi): 0-1 A520, 2-6 A720, 7 X4.
        cores=[dict(mpidr=0x000, mhz=2265), dict(mpidr=0x100, mhz=2265),
               dict(mpidr=0x200, mhz=3149), dict(mpidr=0x300, mhz=3149),
               dict(mpidr=0x400, mhz=3149), dict(mpidr=0x500, mhz=3149),
               dict(mpidr=0x600, mhz=3149), dict(mpidr=0x700, mhz=3302)],
        compat=(b'oneplus,waffle', b'qcom,sm8650'),
    ),
}

# The iOS userland is the iPhone X (iPhone10,3 / D22AP) IPSW. MobileGestalt
# derives product type, device class, home-button-less UI, artwork etc. from
# the root identity and /product of the real D22AP device tree. That tree is
# an Apple artifact (kept out of git): extract it from the IPSW with
#   tools/remotezip.py URL DeviceTree.d22ap.im4p DIR
#   ipsw img4 im4p extract DIR/Firmware/all_flash/DeviceTree.d22ap.im4p -o d22ap.adt
D22AP_ADT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../research/ipsw-x/d22ap.adt')


def d22ap_product(path=D22AP_ADT):
    """/product properties of the real D22AP tree, without the syscfg
    placeholders iBoot would fill in (flag bit set) and the node bookkeeping."""
    if not os.path.exists(path):
        print(f'warning: {path} missing, no /product node', file=sys.stderr)
        return None
    root, _ = adt.parse(open(path, 'rb').read())
    for c in root.children:
        if dict((k, v) for k, f, v in c.props).get('name') == b'product\0':
            return [(k, v) for k, f, v in c.props if not f and k not in ('name', 'AAPL,phandle')]
    raise SystemExit(f'{path}: no /product node')

u32 = lambda *v: struct.pack('<%dI' % len(v), *v)
u64 = lambda *v: struct.pack('<%dQ' % len(v), *v)
cstr = lambda s: (s if isinstance(s, bytes) else s.encode()) + b'\0'


def node(name, props=(), children=()):
    n = adt.Node()
    n.props = [('name', 0, cstr(name))] + [(k, 0, v) for k, v in props]
    n.children = list(children)
    return n


def build(seed=None, qemu=False, highmem=False, device='sweet',
          fb=None, phys_base=None, mem_size=None):
    """qemu=True: same tree, but with QEMU virt's GIC addresses and CNTFRQ (tools/qemu-sweet.py).

    device selects the board profile ('sweet' or 'waffle'); fb is an optional
    dict(addr, size, w, h, stride) overriding the profile's framebuffer values
    (needed for waffle once the real splash address is known); phys_base and
    mem_size override the kernel-managed RAM region.
    """
    p = PROFILES[device]
    if qemu:
        gicd, gicr, gicr_size, gicr_stride, timebase, vtimer = (
            QEMU_GICD, QEMU_GICR, 0x100000, None, QEMU_TIMEBASE, QEMU_VTIMER_INTID)
    else:
        gicd, gicr, gicr_size, gicr_stride, timebase, vtimer = (
            p['gicd'], p['gicr'], p['gicr_size'], p['gicr_stride'], p['timebase'], p['vtimer'])
    if phys_base is None:
        phys_base = (p['high_phys_base'] if highmem else p['phys_base'])
        mem_size = (p['high_mem_size'] if highmem else p['mem_size'])
    fb = dict(fb_addr=p['fb'], fb_size=p['fb_size'], fb_w=p['fb_w'],
              fb_h=p['fb_h'], fb_stride=p['fb_stride']) if fb is None else dict(fb)
    seed = seed if seed is not None else os.urandom(64)
    phandle = iter(range(1, 1000))
    ph = lambda: ('AAPL,phandle', u32(next(phandle)))

    chosen = node('chosen', [
        ph(),
        ('dram-base', u64(phys_base)),
        ('dram-size', u64(mem_size)),
        ('random-seed', seed),
        ('debug-enabled', u32(1)),
        ('firmware-version', cstr('sweet-shim')),
        ('system-firmware-version', cstr('sweet-shim')),
        # iBoot's SHA-384 of the boot manifest; /sbin/mount -P 1 exits unless
        # it exists (bind mounts /private/preboot/<hex>/usr/standalone/firmware,
        # tolerating a missing directory). Fixed stand-in value.
        ('boot-manifest-hash', BOOT_MANIFEST_HASH),
        # libimg4 (cryptexd) aborts "failed to get crypto algorithm" without
        # it; real A11+ device trees say sha2-384.
        ('crypto-hash-method', cstr('sha2-384')),
        # MobileGestalt's screen class: display-scale (u32, default 0) comes
        # from /chosen, the pixel size from IOMobileFramebuffer. Scale 0 makes
        # SpringBoard's FBSDisplayMode "infxinf@0x" invalid. 1080x2400 @3x =
        # 360x800 points (like iPhone X class devices).
        ('display-scale', u32(3)),
        # XNU derives IOPlatformUUID (gethostuuid) from these on arm; without
        # them CFPreferences cannot use kCFPreferencesCurrentHost (no ByHost
        # files), so e.g. DataMigration never records LastSystemVersion and
        # migrates on every boot. Synthetic ECID (not the phone's); chip-id
        # of the A11 that the iPhone X userland expects.
        ('unique-chip-id', struct.pack('<Q', SWEET_ECID)),
        ('chip-id', u32(0x8015)),
        # Security status as on a dev-fused, undemoted board (tuple 0,0,1,1):
        # MobileGestalt reads these from /chosen, and mobileactivationd's
        # DeviceType then takes its native "Hactivation" branch (state
        # Activated without an activation record; no SEP, no baseband here).
        ('certificate-production-status', u32(0)),
        ('effective-production-status-ap', u32(0)),
        ('certificate-security-mode', u32(1)),
        ('effective-security-mode-sep', u32(1)),
    ], [node('memory-map', [ph()]),
        # Local boot policy (kern_csr.c): SIP relaxed like `csrutil disable`
        # (lp-sip0: untrusted kexts, unrestricted FS, task_for_pid, kernel
        # debugger, dtrace, nvram), lp-sip1: unauthenticated (unsealed) root.
        # The iOS shared cache is in no trust cache, so dyld can only map it
        # with CSR_ALLOW_UNRESTRICTED_FS (vm_unix.c shared region checks).
        node('asmb', [ph(), ('lp-sip0', u64(0x6f)), ('lp-sip1', u32(1))])])

    # SWEET SMP: all eight cores in physical-core order, one homogeneous
    # cluster (sweet: 0-5 A55, 6-7 A76; waffle: 0-1 A520, 2-6 A720, 7 X4).
    # The kernel defaults to one and uses cpus=N to select an initial prefix.
    # QEMU retains its original single-CPU tree: its MPIDRs differ.
    cpu_nodes = []
    for core in range(1 if qemu else len(p['cores'])):
        c = p['cores'][core]
        cpu_nodes.append(node(f'cpu{core}', [
            ph(),
            ('device_type', cstr('cpu')),
            ('compatible', cstr('qcom,kryo470') + cstr('ARM,v8')),
            ('reg', u32(c['mpidr'])),  # actual MPIDR Aff1:Aff0, NOT logical ID
            ('cpu-id', u32(core)),   # descriptive: XNU assigns IDs by DT order
            ('cluster-id', u32(0)),  # descriptive; see ml_parse_cpu_topology
            ('cluster-type', u32(0)),  # homogeneous CLUSTER_TYPE_SMP, not AMP
            ('die-cluster-id', u32(0)),
            ('cluster-core-id', u32(core)),
            ('l2-cache-id', u32(core)),  # distinct per-core L2 nodes in live FDT
            ('l3-cache-id', u32(0)),     # shared L3
            ('state', cstr('running' if core == 0 else 'stopped')),
            ('timebase-frequency', u32(timebase)),
            ('clock-frequency', u32(c['mhz'] * 1000000)),
            ('bus-frequency', u32(100000000)),
            ('memory-frequency', u32(1866000000)),
            ('peripheral-frequency', u32(timebase)),
            ('fixed-frequency', u32(timebase)),
        ]))
    cpus = node('cpus', [ph(), ('#address-cells', u32(1)),
                         ('#size-cells', u32(0))], cpu_nodes)

    gic_props = [
        ph(),
        ('compatible', cstr('arm,gic-v3')),
        ('interrupt-controller', b''),
        ('virtual-timer-intid', u32(vtimer)),
        ('reg', u64(gicd - SOC_BASE, p['gicd_size'], gicr - SOC_BASE, gicr_size)),
    ]
    # GIC-600 (waffle): 256 KiB per redistributor frame (two 64K frames);
    # pe_fiq.c's find_gicr_pe_base() strides by this value (patch 0080).
    if gicr_stride:
        gic_props.append(('redistributor-stride', u32(gicr_stride)))
    gic = node('gic', gic_props)
    arm_io = node('arm-io', [
        ph(),
        ('device_type', cstr('sweet-io')),
        ('compatible', cstr('sweet-io') + cstr('arm-io')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
        ('ranges', u64(0, SOC_BASE, 0x100000000 - SOC_BASE)),
    ], [gic,
        # No hardware: watchdogd checks IODeviceTree:/arm-io/wdt for no-pmu and
        # otherwise crashes trying to set the PMU boot stage (customer builds
        # ignore the -wdt_no_pmu boot-arg).
        node('wdt', [ph(), ('no-pmu', u32(1))]),
        # Main display: IOMobileFramebuffer.framework counts /arm-io children
        # with this device_type and reads the canvas size from the node
        # (the presented iPhone X size, see SweetFramebuffer.cpp);
        # the kernel's AppleCLCD matches the compatible string.
        node('disp0', [
            ph(),
            ('device_type', cstr('display-subsystem')),
            ('compatible', cstr('sweet,display')),
            ('canvas-width', u32(1125)),
            ('canvas-height', u32(2436)),
        ])])

    fbcon = node('sweet-fbcon', [
        ph(),
        ('reg', u64(fb['fb_addr'], fb['fb_size'])),
        ('width', u32(fb['fb_w'])),
        ('height', u32(fb['fb_h'])),
        ('stride', u32(fb['fb_stride'])),
    ])

    # bsd/dev/sweet_ufs.c: the UFS host ABL leaves running (absolute physical reg).
    ufs = node('sweet-ufs', [
        ph(),
        ('compatible', cstr('qcom,ufshc')),
        ('reg', u64(p['ufs'], p['ufs_size'])),
    ])

    # pmap_compute_max_asids requires the node even when no overrides are set.
    # An absent pmap-max-asids property selects XNU's own MAX_ASIDS default.
    # No effaceable storage: keybagd then reads /private/var/keybags/systembag.kb
    # as a plain plist instead of decrypting it with the effaceable key.
    defaults = node('defaults', [ph(), ('no-effaceable-storage', u32(1))])

    # MobileGestalt HomeButtonType = IODeviceTree:/buttons home-button-type
    # (D22AP: 2, no Home button; absent = 0 = Home-button device).
    buttons = node('buttons', [
        ph(),
        ('button-names', cstr('volup') + cstr('voldown') + cstr('hold')),
        ('home-button-type', u32(2)),
        ('opposed-power-vol-buttons', u32(1)),
    ])

    product_props = d22ap_product()
    product = [node('product', [ph()] + product_props)] if product_props else []

    # Identity of the iPhone X whose userland runs here: compatible[0] is
    # hw.model/hw.target (D22AP), model is hw.machine/hw.product
    # (iPhone10,3). The board compatible string matches SweetPlatformExpert
    # (IONameMatch); SoC/board strings are informational.
    board_compat = cstr('D22AP') + cstr('iPhone10,3')
    for s in p['compat']:
        board_compat += cstr(s)
    board_compat += cstr('AppleARM')
    return node('device-tree', [
        ph(),
        ('compatible', board_compat),
        ('model', cstr('iPhone10,3')),
        ('target-type', cstr('D22')),
        ('target-sub-type', cstr('D22AP')),
        ('manufacturer', cstr('Apple Inc.')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
    ], [chosen, defaults, cpus, arm_io, fbcon, buttons] + product + ([] if qemu else [ufs]))


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--dump', action='store_true')
    ap.add_argument('--qemu', action='store_true')
    ap.add_argument('--highmem', action='store_true')
    ap.add_argument('--device', choices=PROFILES, default='sweet')
    ap.add_argument('--phys-base', type=lambda s: int(s, 0))
    ap.add_argument('--mem-size', type=lambda s: int(s, 0))
    ap.add_argument('--fb-addr', type=lambda s: int(s, 0), help='panel/splash physical address')
    ap.add_argument('--fb-w', type=int)
    ap.add_argument('--fb-h', type=int)
    ap.add_argument('--fb-stride', type=int)
    ap.add_argument('--fb-size', type=lambda s: int(s, 0))
    a = ap.parse_args()
    fb = None
    if a.fb_w or a.fb_h or a.fb_addr:
        p = PROFILES[a.device]
        fb = dict(fb_addr=a.fb_addr if a.fb_addr is not None else p['fb'],
                  fb_size=a.fb_size if a.fb_size is not None else p['fb_size'],
                  fb_w=a.fb_w or p['fb_w'], fb_h=a.fb_h or p['fb_h'],
                  fb_stride=a.fb_stride or (a.fb_w or p['fb_w']) * 4)
    root = build(qemu=a.qemu, highmem=a.highmem, device=a.device,
                 fb=fb, phys_base=a.phys_base, mem_size=a.mem_size)
    blob = adt.serialize(root)
    open(a.out, 'wb').write(blob)
    if a.dump:
        adt.dump(adt.parse(blob)[0])
    print(f'{a.out}: {len(blob)} bytes ({a.device})', file=sys.stderr)
