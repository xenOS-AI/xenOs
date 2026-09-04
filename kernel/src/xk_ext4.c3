module xk;

// ============================================================================
// xenOS ext4 READ-ONLY root filesystem driver (Phase C). Read path validated in
// C3 host-side first (tools/ext4read.c3 vs mke2fs + e2fsck); this is the same
// parser in-kernel. Block reads go through ATA PIO from the SECONDARY IDE SLAVE
// (the ext4 image is attached with `if=ide,index=3`).
//  v1 contract: 1024-byte blocks, EXTENTS-only (magic 0xF30A, depth-0 leaves),
//  filetype directory entries (linear scan), inline symlinks (size<=60).
// Mirrors the FAT layering: files are loaded whole into a kernel buffer at open.
// ============================================================================
const uint E4_BASE  = 0x170;      // secondary IDE channel
const uint E4_DRIVE = 0x10;       // slave
uint g_e4 = 0;                    // 1 when the ext4 rootfs is mounted
uint g_e4_bs;                     // block size (1024)
uint g_e4_isz;                    // inode size (256)
uint g_e4_ibtab;                  // group-0 inode-table block
char[1024] g_e4_blk;              // 1024-byte block cache
char[256]  g_e4_ino;              // current inode buffer
char[16384] g_e4_dir;             // directory-scan scratch (multi-block dirs, e.g. /usr/lib has 150+ entries)
char[1024] g_e4_leaf;             // depth-1 extent-tree LEAF block cache

fn uint e4_u16(ulong b, ulong o)
{
    return (uint)(((char*)b)[o]) | ((uint)(((char*)b)[o + 1]) << 8);
}
fn uint e4_u32(ulong b, ulong o)
{
    return (uint)(((char*)b)[o]) | ((uint)(((char*)b)[o + 1]) << 8)
         | ((uint)(((char*)b)[o + 2]) << 16) | ((uint)(((char*)b)[o + 3]) << 24);
}

// Read ext4 block `blk` (1024 bytes) from the secondary-slave disk via ATA PIO.
fn void e4_block(uint blk)
{
    ata_read_sectors(E4_BASE, E4_DRIVE, (ulong)blk * 2, 2, &g_e4_blk[0]);   // 2 x 512B sectors
}
// Read a depth-1 extent-tree LEAF block into g_e4_leaf (kept separate from g_e4_blk,
// which holds file DATA blocks, so iterating a leaf's extents never clobbers its entries).
fn void e4_leaf_block(uint blk)
{
    ata_read_sectors(E4_BASE, E4_DRIVE, (ulong)blk * 2, 2, &g_e4_leaf[0]);
}

fn bool e4_mount()
{
    e4_block(1);                                   // superblock at block 1 (byte 1024)
    if (e4_u16((ulong)&g_e4_blk[0], 56) != 0xEF53u) return false;
    g_e4_bs = 1024u << e4_u32((ulong)&g_e4_blk[0], 24);
    g_e4_isz = e4_u16((ulong)&g_e4_blk[0], 88);
    e4_block(2);                                   // group-0 descriptor block
    g_e4_ibtab = e4_u32((ulong)&g_e4_blk[0], 8);   // inode-table block
    g_e4 = 1;
    return true;
}

fn void e4_load_inode(uint n)
{
    uint per = 1024u / g_e4_isz;                       // 4 inodes per 1024-byte block
    uint blk = g_e4_ibtab + (n - 1) / per;
    uint off = ((n - 1) % per) * g_e4_isz;
    e4_block(blk);
    for (uint i = 0; i < g_e4_isz; i++) { g_e4_ino[i] = g_e4_blk[off + i]; }
}

fn uint e4_mode(uint ino)
{
    e4_load_inode(ino);
    return e4_u16((ulong)&g_e4_ino[0], 0);
}
fn uint e4_size(uint ino)
{
    e4_load_inode(ino);
    return e4_u32((ulong)&g_e4_ino[0], 4);   // 32-bit size (large_file disabled)
}

// Fetch depth-0 extent idx of the loaded inode. Returns false at end / not-extents.
fn bool e4_extent(uint idx, uint* lb, uint* elen, uint* phys)
{
    if (e4_u16((ulong)&g_e4_ino[0], 40) != 0xF30Au) return false;
    uint entries = e4_u16((ulong)&g_e4_ino[0], 42);
    uint depth = e4_u16((ulong)&g_e4_ino[0], 46);
    if (depth != 0) return false;
    if (idx >= entries) return false;
    ulong e = (ulong)&g_e4_ino[0] + 52 + (ulong)idx * 12;
    *lb = e4_u32(e, 0);
    *elen = e4_u16(e, 4) & 0x7FFFu;
    *phys = e4_u32(e, 8);
    return true;
}

// Copy the data (or inline symlink target) of inode `ino` to `out` (<= max).
fn void e4_data(uint ino, char* out, uint max, uint* nout)
{
    uint mode = e4_mode(ino);
    uint size = e4_size(ino);
    if ((mode & 0xF000u) == 0xA000u && size <= 60)
    {
        for (uint k = 0; k < size && k < max; k++) { out[k] = g_e4_ino[40 + k]; }
        *nout = size;
        return;
    }
    uint idx = 0;
    uint off = 0;    // highest file byte written so far (for the final count/holes)
    uint depth = e4_u16((ulong)&g_e4_ino[0], 46);
    if (depth == 0)
    {
        // depth-0: leaf extents are inline in the inode i_block (at +52).
        // Position each extent at its LOGICAL block (ee_block): sparse files skip
        // zero runs, so bytes must land at ee_block*1024, leaving holes as zeros.
        uint entries = e4_u16((ulong)&g_e4_ino[0], 42);
        for (idx = 0; idx < entries; idx++)
        {
            ulong e = (ulong)&g_e4_ino[0] + 52 + (ulong)idx * 12;
            uint lb = e4_u32(e, 0);
            uint elen = e4_u16(e, 4) & 0x7FFFu;
            uint ph = e4_u32(e, 8);
            for (uint k = 0; k < elen; k++)
            {
                uint dst = lb * 1024u + k * 1024u;
                if (dst >= size || dst >= max) break;
                e4_block(ph);
                uint take = 1024u;
                if (take > size - dst) take = size - dst;
                if (take > max - dst) take = max - dst;
                for (uint q = 0; q < take; q++) { out[dst + q] = g_e4_blk[q]; }
                if (dst + take > off) off = dst + take;
                ph++;
            }
        }
    }
    else
    {
        // depth-1: inode holds INTERIOR entries (ee_leaf_lo@4 | ee_leaf_hi@8<<16)
        // pointing at LEAF blocks; walk each leaf's extents in logical order.
        uint entries = e4_u16((ulong)&g_e4_ino[0], 42);
        for (idx = 0; idx < entries; idx++)
        {
            ulong ie = (ulong)&g_e4_ino[0] + 52 + (ulong)idx * 12;
            uint leaf_blk = e4_u32(ie, 4) | (e4_u16(ie, 8) << 16);
            e4_leaf_block(leaf_blk);
            if (e4_u16((ulong)&g_e4_leaf[0], 0) != 0xF30Au) continue;
            if (e4_u16((ulong)&g_e4_leaf[0], 6) != 0) continue;   // deeper than depth-1: unsupported (TODO)
            uint lent = e4_u16((ulong)&g_e4_leaf[0], 2);
            for (uint li = 0; li < lent; li++)
            {
                ulong le = (ulong)&g_e4_leaf[0] + 12 + (ulong)li * 12;
                uint lb = e4_u32(le, 0);
                uint elen = e4_u16(le, 4) & 0x7FFFu;
                uint ph = e4_u32(le, 8);
                for (uint k = 0; k < elen; k++)
                {
                    uint dst = lb * 1024u + k * 1024u;
                    if (dst >= size || dst >= max) break;
                    e4_block(ph);
                    uint take = 1024u;
                    if (take > size - dst) take = size - dst;
                    if (take > max - dst) take = max - dst;
                    for (uint q = 0; q < take; q++) { out[dst + q] = g_e4_blk[q]; }
                    if (dst + take > off) off = dst + take;
                    ph++;
                }
            }
        }
    }
    *nout = off;
}

// Offset-aware ext4 read: copy bytes [file_start .. file_start+max) of inode `ino`
// into `out`, streaming blocks from the (depth-0 or depth-1) extent tree. Skips
// blocks entirely before `file_start`; stops once past the window. Returns bytes
// actually copied in *nout. Needed for the multi-MB .so (libgtk-3.so etc) that a
// 64KB open cap / kernel-heap round-trip cannot fit -- file-backed mmap streams
// each page directly into the identity user region.
fn void e4_pread(uint ino, char* out, uint file_start, uint max, uint* nout)
{
    // SPARSE-FILE SAFETY: zero the whole window first so holes read as zeros, not
    // uninitialized garbage (musl reads .dynstr/.dynsym which often sit past a hole).
    for (uint z = 0; z < max && z < (uint)0x800000; z++) { out[z] = 0; }
    uint mode = e4_mode(ino);
    uint size = e4_size(ino);
    if ((mode & 0xF000u) == 0xA000u && size <= 60)
    {
        *nout = 0;
        for (uint k = 0; k < max; k++)
        {
            uint src = file_start + k;
            if (src >= size) break;
            out[k] = g_e4_ino[40 + src];
            *nout = k + 1;
        }
        return;
    }
    uint copied = 0;
    uint depth = e4_u16((ulong)&g_e4_ino[0], 46);
    if (depth == 0)
    {
        uint entries = e4_u16((ulong)&g_e4_ino[0], 42);
        for (uint idx = 0; idx < entries; idx++)
        {
            ulong e = (ulong)&g_e4_ino[0] + 52 + (ulong)idx * 12;
            uint lb = e4_u32(e, 0);
            uint elen = e4_u16(e, 4) & 0x7FFFu;
            uint ph = e4_u32(e, 8);
            for (uint k = 0; k < elen; k++)
            {
                uint dst = lb * 1024u + k * 1024u;
                if (dst >= file_start + max) { k = elen; break; }
                if (dst + 1024u > file_start)   // overlaps the window
                {
                    e4_block(ph);
                    uint begin = dst > file_start ? dst : file_start;
                    uint end = dst + 1024u < file_start + max ? dst + 1024u : file_start + max;
                    if (end > size) end = size;
                    for (uint q = begin; q < end; q++) { out[q - file_start] = g_e4_blk[q - dst]; }
                    if (end > copied) copied = end;   // track HIGHEST covered offset
                }
                ph++;
            }
        }
    }
    else
    {
        uint entries = e4_u16((ulong)&g_e4_ino[0], 42);
        for (uint idx = 0; idx < entries; idx++)
        {
            ulong ie = (ulong)&g_e4_ino[0] + 52 + (ulong)idx * 12;
            uint leaf_blk = e4_u32(ie, 4) | (e4_u16(ie, 8) << 16);
            e4_leaf_block(leaf_blk);
            if (e4_u16((ulong)&g_e4_leaf[0], 0) != 0xF30Au) continue;
            if (e4_u16((ulong)&g_e4_leaf[0], 6) != 0) continue;
            uint lent = e4_u16((ulong)&g_e4_leaf[0], 2);
            for (uint li = 0; li < lent; li++)
            {
                ulong le = (ulong)&g_e4_leaf[0] + 12 + (ulong)li * 12;
                uint lb = e4_u32(le, 0);
                uint elen = e4_u16(le, 4) & 0x7FFFu;
                uint ph = e4_u32(le, 8);
                for (uint k = 0; k < elen; k++)
                {
                    uint dst = lb * 1024u + k * 1024u;
                    if (dst >= file_start + max) { k = elen; break; }
                    if (dst + 1024u > file_start)
                    {
                        e4_block(ph);
                        uint begin = dst > file_start ? dst : file_start;
                        uint end = dst + 1024u < file_start + max ? dst + 1024u : file_start + max;
                        if (end > size) end = size;
                        for (uint q = begin; q < end; q++) { out[q - file_start] = g_e4_blk[q - dst]; }
                        if (end > copied) copied = end;
                    }
                    ph++;
                }
            }
        }
    }
    // `copied` is the HIGHEST file offset covered within the window (absolute);
    // convert to a window-relative byte count for the caller's tail-zero-fill.
    *nout = copied > file_start ? copied - file_start : 0;
}

// Linear-scan directory inode `ino` for `want`; writes child inode to `out_ino`.
// Reads the WHOLE directory (all its extent blocks) into g_e4_dir -- a single
// 4KB read silently misses entries past the first block, so /usr/lib's 150+
// libs (9KB dir) returned ENOENT for anything past entry ~64 (e.g. libwayland,
// libz, libxcb, libpangoft2). Keep the buffer 4x the read cap.
fn bool e4_dir_lookup(uint ino, char* want, uint* out_ino)
{
    uint ln = 0;
    e4_data(ino, &g_e4_dir[0], 16384, &ln);
    uint wantlen = 0;
    while (want[wantlen]) wantlen++;
    uint off = 0;
    while (off + 8 <= ln)
    {
        uint i2 = e4_u32((ulong)&g_e4_dir[0], (ulong)off);
        uint reclen = e4_u16((ulong)&g_e4_dir[0], (ulong)off + 4);
        uint namelen = (uint)(char)g_e4_dir[off + 6];
        if (reclen == 0) break;
        if (i2 != 0 && namelen == wantlen)
        {
            bool match = true;
            for (uint k = 0; k < namelen; k++) { if (g_e4_dir[off + 8 + k] != want[k]) { match = false; break; } }
            if (match) { *out_ino = i2; return true; }
        }
        off += reclen;
    }
    return false;
}

// Resolve `path` from directory inode `base` (root=2), following inline symlinks
// relative to their containing dir. Returns final inode (0 = ENOENT).
fn uint e4_resolve_from(uint base, char* path)
{
    int i = 0;
    while (path[i] == '/') i++;
    while (path[i] != 0)
    {
        char[256] comp;
        uint cl = 0;
        while (path[i] != 0 && path[i] != '/') { comp[cl] = path[i]; cl++; i++; }
        comp[cl] = 0;
        uint next = 0;
        if (!e4_dir_lookup(base, &comp[0], &next)) return 0;
        uint nm = e4_mode(next);
        uint nsz = e4_size(next);
        if ((nm & 0xF000u) == 0xA000u && nsz <= 60)
        {
            char[256] tgt;
            for (uint k = 0; k < nsz; k++) { tgt[k] = g_e4_ino[40 + k]; }
            tgt[nsz] = 0;
            return tgt[0] == '/' ? e4_resolve_from(2, &tgt[0]) : e4_resolve_from(base, &tgt[0]);
        }
        base = next;
        while (path[i] == '/') i++;
    }
    return base;
}

fn uint e4_resolve(char* path) { return e4_resolve_from(2, path); }