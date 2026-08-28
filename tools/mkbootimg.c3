module mkbootimg;
// ============================================================================
// xenOS ISO boot-image tool — freestanding HOST program (no libc/stdlib), raw
// Linux syscalls via host_start.asm. Builds the El Torito no-emulation boot
// image = [iso_boot.bin (loader) | kernel.bin], patching the KLEN dword at
// loader offset 0x3F0 with the kernel length so the loader can copy it.
// ============================================================================

const int O_RDONLY = 0;
const int O_WRONLY = 1;
const int O_CREAT  = 64;
const int O_TRUNC  = 512;
const long BUF = 0x00040000;   // 256 KiB staging (loader + kernel fit easily)
const int  KLEN_OFF = 0x3F0;   // where the loader expects the kernel length

char[BUF] g_buf;               // loader then kernel

extern fn long lx_syscall(long n, long a, long b, long c, long d);
fn long lx_open(char* p, long fl) { return lx_syscall(2, (long)p, fl, 0, 0); }
fn long lx_read(long fd, char* b, long n) { return lx_syscall(0, fd, (long)b, n, 0); }
fn long lx_write(long fd, char* b, long n){ return lx_syscall(1, fd, (long)b, n, 0); }
fn long lx_close(long fd)         { return lx_syscall(3, fd, 0, 0, 0); }

fn void* memset(void* dst, int val, ulong n) @export("memset")
{
    char* p = (char*)dst;
    for (ulong i = 0; i < n; i++) { p[i] = (char)val; }
    return dst;
}

fn long read_full(long fd, char* dst)
{
    long total = 0;
    while (total < BUF)
    {
        long r = lx_read(fd, dst + total, BUF - total);
        if (r <= 0) break;
        total += r;
    }
    return total;
}

fn int xk_host_main(int argc, char** argv) @export("xk_host_main")
{
    const char* USAGE = "usage: mkbootimg <loader.bin> <kernel.bin> <out.bootimg>\n";
    if (argc != 4) { lx_write(2, (char*)USAGE, 44); return 1; }
    long lfd = lx_open(argv[1], O_RDONLY);
    long lsz = read_full(lfd, &g_buf[0]);
    lx_close(lfd);
    long kfd = lx_open(argv[2], O_RDONLY);
    long ksz = read_full(kfd, &g_buf[lsz]);
    lx_close(kfd);
    // patch KLEN at loader offset 0x3F0 (little-endian u32 of the kernel length)
    g_buf[KLEN_OFF]     = (char)(ksz & 0xFF);
    g_buf[KLEN_OFF + 1] = (char)((ksz >> 8) & 0xFF);
    g_buf[KLEN_OFF + 2] = (char)((ksz >> 16) & 0xFF);
    g_buf[KLEN_OFF + 3] = (char)((ksz >> 24) & 0xFF);
    long fd = lx_open(argv[3], O_WRONLY | O_CREAT | O_TRUNC);
    lx_write(fd, &g_buf[0], lsz + ksz);
    lx_close(fd);
    return 0;
}