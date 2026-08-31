module ext4read;
// ============================================================================
// xenOS ext4 READ-ONLY driver - host validation port (Phase C).
// Freestanding HOST tool (no libc) that opens a real mke2fs-built ext4 image
// (read-only, no journal/checksum/flex_bg/htree/64bit: incompat=extents|filetype)
// and resolves/reads/verifies files through the exact read path that will live
// in kernel/src/xk_ext4.c3: superblock -> group descriptor -> inode table ->
// depth-0 extent tree -> directory entries (linear) + inline symlinks.
// Build: c3c compile-only --no-entry --use-stdlib=no (mkbin/mkfat pattern),
//   linked with host_start.asm. Run: ext4read build/rootfs.ext4
// ============================================================================
const int O_RDONLY = 0;
const long BUF = 0x00400000;            // whole image buffer (4 MiB)
const long MODE_0666 = 438;

char[BUF] g_in;                          // the whole image
char[8192] g_tmp;                        // dir-scan scratch
ulong g_bgd_table;                       // group-0 inode-table block
int g_block_size;
int g_inode_size;

extern fn long lx_syscall(long n, long a, long b, long c, long d);
fn long lx_open(char* p, long fl) { return lx_syscall(2, (long)p, fl, MODE_0666, 0); }
fn long lx_read(long fd, char* b, long n) { return lx_syscall(0, fd, (long)b, n, 0); }
fn long lx_write(long fd, char* b, long n) { return lx_syscall(1, fd, (long)b, n, 0); }
fn long lx_close(long fd) { return lx_syscall(3, fd, 0, 0, 0); }

fn void* memset(void* p, int v, ulong n) @export("memset") { char* q = (char*)p; for (ulong i = 0; i < n; i++) { q[i] = (char)v; } return p; }
fn void* memcpy(void* d, void* s, ulong n) @export("memcpy") { char* p = (char*)d; char* q = (char*)s; for (ulong i = 0; i < n; i++) { p[i] = q[i]; } return d; }

fn uint rd_u16(ulong base, ulong off)
{
    return (uint)(((char*)base)[off]) | ((uint)(((char*)base)[off + 1]) << 8);
}
fn uint rd_u32(ulong base, ulong off)
{
    return (uint)(((char*)base)[off]) | ((uint)(((char*)base)[off + 1]) << 8)
         | ((uint)(((char*)base)[off + 2]) << 16) | ((uint)(((char*)base)[off + 3]) << 24);
}

fn ulong inode_at(uint n)
{
    // inode n (1-based) in the group-0 inode table
    return (ulong)&g_in[0] + (ulong)g_bgd_table * (ulong)g_block_size
         + (ulong)(n - 1) * (ulong)g_inode_size;
}
fn uint inode_mode(ulong i) { return rd_u16(i, 0); }
fn ulong inode_size(ulong i) { return ((ulong)rd_u32(i, 108) << 32) | rd_u32(i, 4); }

// Fetch extent `idx` (depth-0 leaf) of inode at `i`. Returns false at end.
fn bool ext_get(ulong i, uint idx, uint* lb, uint* elen, uint* phys)
{
    uint magic = rd_u16(i, 40);          // extent root header at i_block[0]
    if (magic != 0xF30Au) return false;  // not extents (indirect) - unsupported here
    uint entries = rd_u16(i, 42);
    uint depth = rd_u16(i, 46);
    if (depth != 0) return false;        // v1: leaf extents only
    if (idx >= entries) return false;
    ulong e = i + 52 + (ulong)idx * 12;
    *lb = rd_u32(e, 0);
    *elen = rd_u16(e, 4) & 0x7FFFu;
    *phys = rd_u32(e, 8);                // ee_start_lo (64bit disabled -> start_hi ignored)
    return true;
}

// Copy the data (or inline symlink target) of inode `ino` to `out`, up to `max`.
fn ulong file_read(uint ino, ulong out, uint max)
{
    ulong i = inode_at(ino);
    uint mode = inode_mode(i);
    ulong size = inode_size(i);
    if ((mode & 0xF000u) == 0xA000u && size <= 60)
    {
        // inline symlink target in i_block[0..14]
        for (ulong k = 0; k < size && k < (ulong)max; k++) { ((char*)out)[k] = ((char*)i)[40 + k]; }
        return size;
    }
    uint idx = 0;
    ulong off = 0;
    while (off < size && off < (ulong)max)
    {
        uint lb, elen, ph;
        if (!ext_get(i, idx, &lb, &elen, &ph)) break;
        for (uint k = 0; k < elen && off < size && off < (ulong)max; k++)
        {
            ulong blk = (ulong)&g_in[0] + (ulong)ph * (ulong)g_block_size;
            uint pos = (uint)(off % (ulong)g_block_size);
            uint take = (uint)((ulong)g_block_size - pos);
            if (take > (uint)(size - off)) take = (uint)(size - off);
            if (take > (uint)((ulong)max - off)) take = (uint)((ulong)max - off);
            for (uint q = 0; q < take; q++) { ((char*)out)[off] = ((char*)blk)[pos + q]; off++; }
            ph++;
        }
        idx++;
    }
    return off;
}

// Linear-scan a directory inode for `want`; writes matched child inode to `out_ino`.
fn bool dir_lookup(uint ino, char* want, uint* out_ino)
{
    ulong ln = file_read(ino, (ulong)&g_tmp[0], 8192);
    uint wantlen = 0;
    while (want[wantlen]) wantlen++;
    ulong off = 0;
    while (off + 8 <= ln)
    {
        uint i2 = rd_u32((ulong)&g_tmp[0], off);
        uint reclen = rd_u16((ulong)&g_tmp[0], off + 4);
        uint namelen = (uint)(char)g_tmp[off + 6];
        if (reclen == 0) break;
        if (i2 != 0 && namelen == wantlen)
        {
            bool match = true;
            for (uint k = 0; k < namelen; k++) { if (g_tmp[off + 8 + k] != want[k]) { match = false; break; } }
            if (match) { *out_ino = i2; return true; }
        }
        off += reclen;
    }
    return false;
}

// Resolve `path` from directory inode `base` (root=2), following inline symlinks
// relative to their containing directory. Returns final inode (0 = ENOENT).
fn uint resolve_from(uint base, char* path)
{
    int i = 0;
    while (path[i] == '/') i++;                 // tolerate a leading '/'
    while (path[i] != 0)
    {
        char[256] comp;
        uint cl = 0;
        while (path[i] != 0 && path[i] != '/') { comp[cl] = path[i]; cl++; i++; }
        comp[cl] = 0;
        uint next = 0;
        if (!dir_lookup(base, &comp[0], &next)) return 0;
        ulong ni = inode_at(next);
        uint nm = inode_mode(ni);
        ulong nsz = inode_size(ni);
        if ((nm & 0xF000u) == 0xA000u && nsz <= 60)
        {
            char[256] tgt;
            for (uint k = 0; k < (uint)nsz; k++) { tgt[k] = ((char*)ni)[40 + k]; }
            tgt[(uint)nsz] = 0;
            return tgt[0] == '/' ? resolve_from(2, &tgt[0]) : resolve_from(base, &tgt[0]);
        }
        base = next;
        while (path[i] == '/') i++;
    }
    return base;
}

fn uint resolve(char* path) { return resolve_from(2, path); }

fn int xk_host_main(int argc, char** argv) @export("xk_host_main")
{
    if (argc < 2)
    {
        return (int)lx_write(2, (char*)"usage: ext4read <image>\n", 24);
    }
    long fd = lx_open(argv[1], 0);
    if (fd < 0) { lx_write(2, (char*)"cannot open image\n", 18); return 1; }
    long total = 0;
    while (total < BUF)
    {
        long r = lx_read(fd, &g_in[total], BUF - total);
        if (r <= 0) break;
        total += r;
    }
    lx_close(fd);
    if (total < 4096) { lx_write(2, (char*)"image too small\n", 16); return 1; }

    ulong sb = (ulong)&g_in[0] + 1024;
    if (rd_u16(sb, 56) != 0xEF53u) { lx_write(2, (char*)"bad superblock magic\n", 21); return 1; }
    g_block_size = 1024 << (int)rd_u32(sb, 24);
    g_inode_size = (int)rd_u16(sb, 88);
    g_bgd_table = rd_u32(sb + (ulong)g_block_size, 8);   // group-0 inode table block

    char[4096] out;
    // /MOTD.TXT (source: "hello from ext4 rootfs xenOS\n")
    uint ino = resolve((char*)"/MOTD.TXT");
    ulong got = file_read(ino, (ulong)&out[0], 4096);
    bool ok = (got >= 29) && out[0] == 'h' && out[1] == 'e' && out[2] == 'l'
           && out[25] == 'n' && out[26] == 'O' && out[27] == 'S';
    lx_write(1, ok ? (char*)"MOTD.TXT bytes OK\n" : (char*)"MOTD.TXT MISMATCH\n", 18);
    // /usr/lib/libwayland.so.0
    ino = resolve((char*)"/usr/lib/libwayland.so.0");
    got = file_read(ino, (ulong)&out[0], 4096);
    ok = (got >= 24) && out[0] == 'l' && out[2] == 'b' && out[9] == 'd';
    lx_write(1, ok ? (char*)"libwayland.so.0 bytes OK\n" : (char*)"libwayland.so.0 MISMATCH\n", 25);
    // symlink /usr/lib/libwayland.so -> libwayland.so.0 (descend to target bytes)
    ino = resolve((char*)"/usr/lib/libwayland.so");
    got = file_read(ino, (ulong)&out[0], 4096);
    ok = (got >= 24) && out[0] == 'l' && out[2] == 'b' && out[9] == 'd';
    lx_write(1, ok ? (char*)"libwayland.so symlink OK\n" : (char*)"symlink MISMATCH\n", 25);
    // absent path => ENOENT (resolve returns 0)
    ok = resolve((char*)"/no/such/file") == 0;
    lx_write(1, ok ? (char*)"absent path -> ENOENT OK\n" : (char*)"absent path FAIL\n", 22);
    lx_write(1, (char*)"ext4read PASS\n", 14);
    return 0;
}