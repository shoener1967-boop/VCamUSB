import struct

def analyze(path):
    f = open(path,'rb').read()
    magic_be = struct.unpack('>I', f[:4])[0]
    if magic_be in (0xcafebabe, 0xbebafeca, 0xcafebabf):
        n = struct.unpack('>I', f[4:8])[0]
        for i in range(n):
            cpu, sub, o, s, a = struct.unpack('>IIIII', f[8+i*20:28+i*20])
            if cpu in (0x0100000c, 0x01000017): break
        f = f[o:o+s]
    magic = struct.unpack('<I', f[:4])[0]
    # header flags + ncmds
    filetype = struct.unpack('<I', f[12:16])[0]
    flags = struct.unpack('<I', f[24:28])[0]
    ncmds = struct.unpack('<I', f[16:20])[0]
    off = 32
    cmds = []
    for _ in range(ncmds):
        cmd, sz = struct.unpack('<II', f[off:off+8])
        cmds.append(cmd)
        off += sz
    names = {
        0x1:'LC_SEGMENT', 0x19:'LC_SEGMENT_64', 0x2:'LC_SYMTAB', 0xb:'LC_DYSYMTAB',
        0xc:'LC_LOAD_DYLIB', 0x1d:'LC_CODE_SIGNATURE', 0x1b:'LC_UUID',
        0x80000022:'LC_DYLD_EXPORTS_TRIE', 0x80000023:'LC_DYLD_CHAINED_FIXUPS',
        0x80000028:'LC_FUNCTION_STARTS', 0x80000029:'LC_DATA_IN_CODE',
        0x8000002a:'LC_DYLIB_CODE_SIGN_DRS', 0x80000033:'LC_DYLD_EXPORTS_TRIE',
        0x80000034:'LC_DYLD_CHAINED_FIXUPS', 0x26:'LC_ENCRYPTION_INFO_64',
        0x2e:'LC_BUILD_VERSION', 0x32:'LC_SOURCE_VERSION', 0x80000031:'LC_LINKER_OPTIMIZATION_HINT',
    }
    return hex(magic), hex(filetype), hex(flags), [names.get(c, hex(c)) for c in cmds]

for p in ['dev_VoiceChangerX.dylib', 'dev_VCamProbe.dylib']:
    print('===', p, '===')
    magic, filetype, flags, cmds = analyze(p)
    print('  magic:', magic)
    print('  filetype:', filetype)
    print('  flags:', flags)
    print('  cmds:', cmds)
    print()
