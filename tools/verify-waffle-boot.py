#!/usr/bin/env python3
"""Parse boot.img v3/v4 + SWEETXNU payload v2, print a compact, comparable report."""
import sys, struct, hashlib

def u32(b, o): return struct.unpack_from('<I', b, o)[0]
def u64(b, o): return struct.unpack_from('<Q', b, o)[0]

def parse(path):
    b = open(path, 'rb').read()
    r = {'file': path, 'size': len(b), 'sha256': hashlib.sha256(b).hexdigest()}
    assert b[:8] == b'ANDROID!', 'not a boot image'
    r['kernel_size'] = u32(b, 8)
    r['ramdisk_size'] = u32(b, 12)
    r['os_version'] = hex(u32(b, 16))
    r['header_size'] = u32(b, 20)
    r['header_version'] = u32(b, 40)
    r['cmdline'] = b[44:44+1536].split(b'\0', 1)[0].decode()
    page = 4096
    kernel_off = page
    ramdisk_off = (kernel_off + r['kernel_size'] + page - 1) // page * page
    r['kernel_off'] = hex(kernel_off)
    r['ramdisk_off'] = hex(ramdisk_off)
    kern = b[kernel_off:kernel_off + r['kernel_size']]
    rd = b[ramdisk_off:ramdisk_off + r['ramdisk_size']]
    r['kernel_sha256'] = hashlib.sha256(kern).hexdigest()
    r['ramdisk_sha256'] = hashlib.sha256(rd).hexdigest()
    assert rd[:8] == b'SWEETXNU', 'ramdisk is not a SWEETXNU payload'
    r['payload_version'] = u32(rd, 8)
    r['payload_nsegs'] = u32(rd, 12)
    r['virt_base'] = hex(u64(rd, 0x10))
    r['entry_va'] = hex(u64(rd, 0x18))
    r['adt_off'] = hex(u64(rd, 0x20))
    r['adt_size'] = u64(rd, 0x28)
    r['kernel_end_va'] = hex(u64(rd, 0x30))
    r['phys_base'] = hex(u64(rd, 0x38))
    r['mem_size'] = hex(u64(rd, 0x40))
    r['payload_cmdline'] = rd[0x48:0x48+576].split(b'\0', 1)[0].decode()
    r['fb_base'] = hex(u64(rd, 0x288))
    r['fb_stride'] = u64(rd, 0x290)
    r['fb_w'] = u32(rd, 0x298)
    r['fb_h'] = u32(rd, 0x29c)
    r['fb_depth'] = u32(rd, 0x2a0)
    ao = u64(rd, 0x20); asz = u64(rd, 0x28)
    adt = rd[ao:ao+asz]
    r['adt_sha256'] = hashlib.sha256(adt).hexdigest()
    # ADT magic is 'ADT\0' or big-endian? just report first 16 bytes
    r['adt_head'] = adt[:16].hex()
    return r

def main():
    reps = [parse(p) for p in sys.argv[1:]]
    for r in reps:
        print('==', r['file'])
        for k, v in r.items():
            if k != 'file': print(f'  {k:20s} {v}')
    if len(reps) == 2:
        a, b = reps
        print('== DIFF')
        for k in a:
            if k == 'file': continue
            mark = 'SAME' if a[k] == b[k] else 'DIFF'
            print(f'  {mark}  {k:20s} {a[k]!s} | {b[k]!s}')

if __name__ == '__main__':
    main()
