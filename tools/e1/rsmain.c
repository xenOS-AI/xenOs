// E1-TEMP rootfs program: a tiny freestanding no-libc _start (raw syscalls) that
// fits in ~2 blocks, so the extent reader reads it WHOLLY from the ext4 rootfs.
__attribute__((noreturn))
void _start(void)
{
    const char* m = "E1 ROOTFS: hello from the ext4 rootfs under xenOS!\n";
    long n = 0;
    while (m[n]) n++;
    register long r10 asm("r10") = 0;
    long r;
    asm volatile("syscall" : "=a"(r)
                 : "a"(1L), "D"(1L), "S"((long)m), "d"(n), "r"(r10)
                 : "rcx", "r11", "memory");
    asm volatile("syscall" : : "a"(60L), "D"(0L) : "rcx", "r11", "memory");
    for (;;) {}
}