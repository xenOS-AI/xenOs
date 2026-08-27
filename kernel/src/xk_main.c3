module xk;

extern fn ulong xk_get_bss_start();
extern fn ulong xk_get_bss_end();

// The kernel entry point. MUST be the first function declared in this object so
// the linker places it at 0x100000 (KERNEL_BASE), which is where the
// bootloader's `call` lands.
fn void xk_main() @export("xk_main")
{
    zero_bss();
    xk_boot();
}

// Zero the kernel's .bss (globals must start initialized) before anything else.
fn void zero_bss()
{
    ulong s = xk_get_bss_start();
    ulong e = xk_get_bss_end();
    for (ulong p = s; p < e; p++)
    {
        ((char*)p)[0] = 0;
    }
}