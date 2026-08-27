module mkdisk;
// ============================================================================
// xenOS disk-image assembler — a freestanding HOST tool (no libc/stdlib).
// Uses raw Linux syscalls through the asm helper `lx_syscall` (host_start.asm).
// Replicates tools/mkdisk.py: concatenates stage1+stage2+kernel into a bootable
// raw disk image and patches the kernel LBA + sector count into stage1.
// Build (host): c3c compile-only (freestanding) + nasm host_start.asm, linked
// with ld (-e _start), no libc.
// ============================================================================

const int O_RDONLY = 0;
const int O_WRONLY = 1;
const int O_CREAT  = 64;
const int O_TRUNC  = 512;
const long SEEK_END = 2;
const long SECTOR    = 512;
const long STAGE2_LBA = 1;
const long STAGE2_SECTORS = 60;
const long PATCH_LBA     = 0x1E0;   // stage1: kernel LBA (little-endian u32)
const long PATCH_SECTORS = 0x1E4;   // stage1: kernel sector count (u32 LE)
const long BUF = 0x00400000;        // 4 MiB staging buffer (image is ~81 KiB)

char[BUF] g_img;                    // BSS host buffer

extern fn long lx_syscall(long n, long a, long b, long c, long d);

// Provide the compiler-emitted libc helper under its exact linker name.
fn void* memset(void* dst, int val, ulong n) @export("memset")
{
    char* p = (char*)dst;
    for (ulong i = 0; i < n; i++) { p[i] = (char)val; }
    return dst;
}

fn long lx_open(char* p, long fl)  { return lx_syscall(2, (long)p, fl, 0, 0); }
fn long lx_read(long fd, char* b, long n) { return lx_syscall(0, fd, (long)b, n, 0); }
fn long lx_write(long fd, char* b, long n){ return lx_syscall(1, fd, (long)b, n, 0); }
fn long lx_close(long fd)          { return lx_syscall(3, fd, 0, 0, 0); }
fn long lx_lseek(long fd, long o, long wh){ return lx_syscall(8, fd, o, wh, 0); }

fn long read_full(long fd, char* dst, long cap)
{
    long total = 0;
    while (total < cap)
    {
        long r = lx_read(fd, dst + total, cap - total);
        if (r <= 0) break;
        total += r;
    }
    return total;
}

fn void memzero(char* dst, long n)
{
    for (long i = 0; i < n; i++) { dst[i] = 0; }
}

fn void put_u32le(long off, uint v)
{
    g_img[off + 0] = (char)(v & 0xFF);
    g_img[off + 1] = (char)((v >> 8) & 0xFF);
    g_img[off + 2] = (char)((v >> 16) & 0xFF);
    g_img[off + 3] = (char)((v >> 24) & 0xFF);
}

fn int xk_host_main(int argc, char** argv) @export("xk_host_main")
{
    const char* USAGE = "usage: mkdisk stage1.bin stage2.bin kernel.bin out.img\n";
    if (argc != 5)
    {
        lx_write(2, (char*)USAGE, 55);
        return 1;
    }
    long off = 0;
    // stage1
    long fd1 = lx_open(argv[1], O_RDONLY);
    if (fd1 < 0) { lx_write(2, (char*)"mkdisk: cannot open stage1\n", 27); return 1; }
    long s1 = read_full(fd1, &g_img[off], SECTOR);
    lx_close(fd1);
    if (s1 != SECTOR)                            { lx_write(2, (char*)"mkdisk: stage1 not one sector\n", 31); return 1; }
    if ((g_img[510] != (char)0x55) || (g_img[511] != (char)0xAA)) { lx_write(2, (char*)"mkdisk: stage1 no boot sig\n", 27); return 1; }
    off += SECTOR;
    // stage2 (60 reserved sectors)
    long fd2 = lx_open(argv[2], O_RDONLY);
    if (fd2 < 0) { lx_write(2, (char*)"mkdisk: cannot open stage2\n", 27); return 1; }
    long s2 = read_full(fd2, &g_img[off], STAGE2_SECTORS * SECTOR);
    lx_close(fd2);
    if (s2 > STAGE2_SECTORS * SECTOR)            { lx_write(2, (char*)"mkdisk: stage2 too big\n", 24); return 1; }
    memzero(&g_img[off + s2], STAGE2_SECTORS * SECTOR - s2);
    off += STAGE2_SECTORS * SECTOR;
    // kernel
    long fd3 = lx_open(argv[3], O_RDONLY);
    if (fd3 < 0) { lx_write(2, (char*)"mkdisk: cannot open kernel\n", 28); return 1; }
    long kbase = off;
    long ks = read_full(fd3, &g_img[off], BUF - off);
    lx_close(fd3);
    long ksize_align = ((ks + SECTOR - 1) / SECTOR) * SECTOR;
    memzero(&g_img[off + ks], ksize_align - ks);
    off += ksize_align;
    long ksect = (ks + SECTOR - 1) / SECTOR;
    long klba  = STAGE2_LBA + STAGE2_SECTORS;
    // patch stage1 fields (at offset 0 in the buffer)
    put_u32le(PATCH_LBA, (uint)klba);
    put_u32le(PATCH_SECTORS, (uint)ksect);
    // write the image
    long out = lx_open(argv[4], O_WRONLY | O_CREAT | O_TRUNC);
    if (out < 0) { lx_write(2, (char*)"mkdisk: cannot create output\n", 30); return 1; }
    long w = lx_write(out, &g_img[0], off);
    lx_close(out);
    if (w != off) { lx_write(2, (char*)"mkdisk: short write\n", 21); return 1; }
    lx_write(1, (char*)"mkdisk: kernel_lba=", 20);
    return 0;
}