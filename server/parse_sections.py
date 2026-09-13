import struct

def parse_sections(path):
    f = open(path, 'rb').read()
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
    out = []
    for _ in range(ncmds):
        cmd, sz = struct.unpack('<II', f[off:off+8])
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack('<I', f[off+64:off+68])[0]
            so = off + 72
            for j in range(nsects):
                sname = f[so:so+16].decode('latin1').rstrip('\x00')
                ssize = struct.unpack('<Q', f[so+40:so+48])[0]
                out.append((sname, ssize))
                so += 80
        off += sz
    return out

for p in ['VCamHub_on_device.dylib', 'AVServicesd_on_device.dylib']:
    print('===', p, '===')
    for name, size in parse_sections(p):
        mark = ' <== CONSTRUCTOR' if 'init_func' in name or 'mod_init' in name else ''
        print(f'  {name} ({size}){mark}')
    print()
