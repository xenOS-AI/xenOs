#!/usr/bin/env python3
# Validate full ext4 path resolution + symlinks + file bytes against the mke2fs image.
import struct, sys

def rd(d, off, fmt): return struct.unpack_from(fmt, d, off)[0]

def load(path):
    d = open(path, 'rb').read()
    SB = 1024
    assert rd(d, SB+56, '<H') == 0xEF53
    B = 1024 << rd(d, SB+24, '<I')
    inode_size = rd(d, SB+88, '<H')
    GD = SB + B
    bg_inode_table = struct.unpack('<I', d[GD+8:GD+12])[0]
    return d, B, inode_size, bg_inode_table

def inode(d, B, inode_size, table_blk, n):
    off = table_blk*B + (n-1)*inode_size
    return d[off:off+inode_size]

def imeta(i):
    mode = struct.unpack('<H', i[0:2])[0]
    size = (struct.unpack('<I', i[108:112])[0] << 32) | struct.unpack('<I', i[4:8])[0]
    return mode, size

def extents(i, B, d):
    eh = i[40:52]
    magic = struct.unpack('<H', eh[0:2])[0]
    entries = struct.unpack('<H', eh[2:4])[0]
    depth = struct.unpack('<H', eh[6:8])[0]
    if magic != 0xF30A: return None  # indirect
    out = []
    # single-level leaf extents (depth 0)
    for e in range(entries):
        ex = i[52 + e*12 : 52 + e*12 + 12]
        lb = struct.unpack('<I', ex[0:4])[0]
        ln = struct.unpack('<H', ex[4:6])[0] & 0x7fff
        ph = (struct.unpack('<H', ex[6:8])[0] << 32) | struct.unpack('<I', ex[8:12])[0]
        out.append((lb, ln, ph))
    return out

def read_data(d, ext, size, B):
    b = b''
    for (lb, ln, ph) in ext:
        b += d[ph*B:ph*B+ln*B]
    return b[:size]

def read_inode_data(d, i, B):
    mode, size = imeta(i)
    if (mode & 0xF000) == 0xA000 and size <= 60:
        # inline symlink target in i_block
        return i[40:40+size]
    ext = extents(i, B, d)
    return read_data(d, ext, size, B)

def scan_dir(data, force_linear=True):
    names = []
    off = 0
    while off + 8 <= len(data):
        ino, reclen, namelen, ft = struct.unpack_from('<IHBB', data, off)
        if ino != 0 and namelen:
            names.append((data[off+8:off+8+namelen].decode('utf-8','replace'), ino, ft))
        if reclen == 0: break
        off += reclen
    return names

def resolve(d, B, inode_size, t, path):
    comps = [c for c in path.split('/') if c]
    ino = 2
    for ci, comp in enumerate(comps):
        i = inode(d, B, inode_size, t, ino)
        mode, size = imeta(i)
        if (mode & 0xF000) == 0xA000:
            target = i[40:40+size].decode('utf-8','replace')
            # follow symlink: re-resolve target (relative to current dir => rebase)
            return ('SYMLINK', target, ino)
        data = read_inode_data(d, i, B)
        ent = None
        for (name, n2, ft) in scan_dir(data):
            if name == comp: ent = (n2, ft); break
        if ent is None: return ('ENOENT', None, ino)
        ino, ft = ent
    i = inode(d, B, inode_size, t, ino)
    mode, size = imeta(i)
    return ('FILE', read_inode_data(d, i, B), (mode, size, ino))

if __name__ == '__main__':
    d, B, insz, t = load(sys.argv[1])
    for p in ['/MOTD.TXT', '/README.md', '/usr/lib/libwayland.so.0', '/usr/lib/libwayland.so', '/usr/lib/motd.txt']:
        r = resolve(d, B, insz, t, p)
        print('%-28s -> %s' % (p, r[0]))
        if r[0] == 'FILE':
            b, (mode, size, ino) = r[1], r[2]
            print('    ino=%d mode=%o size=%d bytes=%r' % (ino, mode, size, b))
        elif r[0] == 'SYMLINK':
            print('    points to %r' % r[1])