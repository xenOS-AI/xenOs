/* naked.c - libc-free, SSE-free, stack-free test of xenOS's Linux ELF
 * loader + `syscall` ABI. Pure 64-bit register moves only.
 * Build:  gcc -nostdlib -static -no-pie -mno-sse -mno-sse2 -march=x86-64 -O2 \
 *             -fno-stack-protector -Wl,-e,_start -o build/naked tools/naked.c
 */
__attribute__((section(".rodata"), aligned(8)))
static const char msg[] = "NAKED-OK\n";

__attribute__((noinline))
void _start(void) {
    register long a asm("rax") = 1;          /* write */
    register long d asm("rdi") = 1;          /* fd 1 */
    register long s asm("rsi") = (long)msg;
    register long n asm("rdx") = 9;
    asm volatile("syscall" : "+r"(a) : "r"(d), "r"(s), "r"(n) : "rcx", "r11", "memory");
    register long e asm("rax") = 231;        /* exit_group */
    register long z asm("rdi") = 0;
    asm volatile("syscall" : "+r"(e) : "r"(z) : "rcx", "r11", "memory");
    for (;;) { asm volatile("hlt"); }
}