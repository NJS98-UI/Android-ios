#!/usr/bin/env python3
"""Unpack an Android boot image (header v0-v2) or vendor_boot image (v3-v4)
into kernel/ramdisk/second/dtb/vendor_ramdisk fragments + header.txt.

  unpack_bootv2.py BOOT.img OUT/                 boot.img (ANDROID! magic)
  unpack_bootv2.py vendor_boot.img OUT/          vendor_boot (VNDRBOOT magic)

vendor_boot v4 carries the device DTB (no dtb field exists in boot v4), so
this is how the live waffle DTB is extracted from a stock OnePlus 12 image.
"""
import struct, sys, os

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
b = open(src, 'rb').read()
info = {}
parts = []


def rnd(n, ps):
    return (n + ps - 1) // ps * ps


def emit(name, data):
    if data:
        open(f'{out}/{name}', 'wb').write(data)


def unpack_boot():
    assert b[:8] == b'ANDROID!', 'not a boot image'
    (ks, ka, rs, ra, ss, sa, ta, ps, ver, osv) = struct.unpack_from('<10I', b, 8)
    cmd = b[64:64 + 512].split(b'\0')[0] + b[608:608 + 1024].split(b'\0')[0]
    info.update(kernel_size=ks, kernel_addr=hex(ka), ramdisk_size=rs, ramdisk_addr=hex(ra),
                second_size=ss, tags_addr=hex(ta), page_size=ps, header_version=ver,
                os_version=hex(osv), name=b[48:64].split(b'\0')[0].decode(), cmdline=cmd.decode())
    off = ps
    parts.extend([('kernel', ks), ('ramdisk', rs), ('second', ss)])
    if ver >= 1:
        rds, rdo, hs = struct.unpack_from('<IQI', b, 1632)
        parts.append(('recovery_dtbo', rds)); info['header_size'] = hs
    if ver >= 2:
        ds, da = struct.unpack_from('<IQ', b, 1648)
        parts.append(('dtb', ds)); info['dtb_addr'] = hex(da)


def unpack_vendor():
    assert b[:8] == b'VNDRBOOT', 'not a vendor_boot image'
    ver, ps, ka, ra, vrs = struct.unpack_from('<5I', b, 8)
    cmd = b[28:28 + 2048].split(b'\0')[0]
    hdr_sz, dtb_sz, dtb_addr = struct.unpack_from('<IIQ', b, 2096)
    info.update(header_version=ver, page_size=ps, kernel_addr=hex(ka), ramdisk_addr=hex(ra),
                vendor_ramdisk_size=vrs, vendor_cmdline=cmd.decode(),
                header_size=hdr_sz, dtb_size=dtb_sz, dtb_addr=hex(dtb_addr))
    if ver == 4:
        vrt_sz, vrt_num, vrt_esz, bcfg_sz = struct.unpack_from('<4I', b, 2112)
        info.update(vendor_ramdisk_table_size=vrt_sz, vendor_ramdisk_table_entry_num=vrt_num,
                    vendor_ramdisk_table_entry_size=vrt_esz, bootconfig_size=bcfg_sz)
    off = ps
    rd = b[off:off + vrs]
    emit('vendor_ramdisk', rd)
    info['vendor_ramdisk_offset'] = off
    off += rnd(vrs, ps)
    if dtb_sz:
        emit('dtb', b[off:off + dtb_sz])
        info['dtb_offset'] = off
        off += rnd(dtb_sz, ps)
    if ver == 4 and vrt_sz:
        # v4: one table entry per ramdisk fragment inside vendor_ramdisk
        toff = off
        for i in range(vrt_num):
            e = b[toff + i * vrt_esz: toff + (i + 1) * vrt_esz]
            fsz, foff, ftype = struct.unpack_from('<3I', e, 0)
            fname = e[12:12 + 32].split(b'\0')[0].decode(errors='replace')
            emit(f'vendor_ramdisk-{fname}', rd[foff:foff + fsz])
            info[f'vendor_ramdisk[{i}]'] = f'{fname} type={ftype} size={fsz} offset={foff}'


if b[:8] == b'VNDRBOOT':
    unpack_vendor()
elif b[:8] == b'ANDROID!':
    unpack_boot()
else:
    sys.exit('unknown boot image magic (need ANDROID! or VNDRBOOT)')

for name, sz in parts:
    if sz:
        pass  # boot images are handled by offsets below

if b[:8] == b'ANDROID!':
    ps = info['page_size']
    off = ps
    for name, sz in parts:
        emit(name, b[off:off + sz])
        info[name + '_offset'] = off
        off += rnd(sz, ps)

with open(f'{out}/header.txt', 'w') as f:
    for k, v in info.items():
        f.write(f'{k}: {v}\n')
print(open(f'{out}/header.txt').read())
