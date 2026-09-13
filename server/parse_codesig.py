import struct

def parse_codesig(path):
    f = open(path,'rb').read()
    magic_be = struct.unpack('>I', f[:4])[0]
    if magic_be in (0xcafebabe, 0xbebafeca, 0xcafebabf):
        n = struct.unpack('>I', f[4:8])[0]
        for i in range(n):
            cpu, sub, o, s, a = struct.unpack('>IIIII', f[8+i*20:28+i*20])
            if cpu in (0x0100000c, 0x01000017):
                break
        f = f[o:o+s]
    ncmds = struct.unpack('<I', f[16:20])[0]
    off = 32
    cs = None
    for _ in range(ncmds):
        cmd, sz = struct.unpack('<II', f[off:off+8])
        if cmd == 0x1D:
            cs = struct.unpack('<II', f[off+8:off+16])
        off += sz
    if not cs:
        return None
    dataoff, datasize = cs
    blob = f[dataoff:dataoff+datasize]
    magic, length, count = struct.unpack('>III', blob[:12])
    out = {'blob_magic': hex(magic), 'blob_len': length, 'count': count}
    for i in range(count):
        typ, slot_off = struct.unpack('>II', blob[12+i*8:20+i*8])
        cd = blob[slot_off:]
        cdmagic, cdlen = struct.unpack('>II', cd[:8])
        if typ == 0:  # CodeDirectory
            version = struct.unpack('>I', cd[8:12])[0]
            flags = struct.unpack('>I', cd[12:16])[0]
            ident_off = struct.unpack('>I', cd[20:24])[0]
            ident = cd[ident_off:].split(b'\x00')[0].decode()
            out['cd_version'] = version
            out['cd_flags'] = hex(flags)
            out['cd_ident'] = ident
            fmap = {0x1:'valid', 0x2:'ad-hoc', 0x4:'get-task-allow', 0x8:'installer',
                    0x10:'hardened', 0x20:'kill', 0x40:'restrict', 0x80:'enforcement',
                    0x100:'library-validation', 0x200:'runtime', 0x10000:'linker-signed',
                    0x4000000:'platform', 0x8000000:'debugger'}
            set_flags = [n for bit, n in fmap.items() if flags and bit]
            out['flags_decoded'] = set_flags
        elif typ == 2:  # entitlements
            out['has_entitlements_blob'] = True
        elif typ == 0x10000:  # DER entitlements
            out['has_der_entitlements'] = True
    return out

for p in ['VCamHub_on_device.dylib', 'AVServicesd_on_device.dylib']:
    print('===', p, '===')
    r = parse_codesig(p)
    if r:
        for k, v in r.items():
            print(' ', k, ':', v)
    else:
        print('  KEINE LC_CODE_SIGNATURE')
    print()
