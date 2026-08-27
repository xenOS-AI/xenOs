module xk;

// ============================================================================
// xenOS ring-3 (user-mode) support.
//   * extends the boot GDT with DPL-3 user segments + a 64-bit TSS
//   * maps a 2 MiB page as user-accessible (U/S)
//   * drops to ring 3 in an embedded program (user/sys_prog.asm) that talks
//     to the kernel only via INT 0x80 syscalls, and returns to ring 0 on
//     the SYS_EXIT syscall.
// Selectors (extended boot GDT at 0xF000): user code64 = 0x28, user data64
// = 0x30, TSS = 0x38.
// ============================================================================

const uint USER_CODE = 0x28;
const uint USER_DATA = 0x30;
const uint TSS_SEL   = 0x38;
const ulong USER_BASE = 0x08000000;             // 128 MiB (real RAM under QEMU -m 256)
const uint USER_PDE  = (uint)(USER_BASE >> 21);
const ulong UMODE_KSTACK = 0x90000;             // ring-0 stack switched to on CPL3->CPL0

char[104] g_tss;                        // raw 64-bit TSS (no struct padding)
ulong g_user_resume;                    // ring-0 address SYS_EXIT returns to

// xk_lgdt / xk_ltr are declared in xk_core.c3 (same module).
extern fn void xk_enter_ring3(ulong entry, ulong user_sp);
extern fn void xk_reload_cr3();

fn void gdt_put(int idx, uint lo, uint hi)
{
    uint* p = (uint*)((ulong)0xF000 + (ulong)idx * 8);
    p[0] = lo;
    p[1] = hi;
}

fn void tss_put_desc(ulong base, uint limit)
{
    uint* g = (uint*)((ulong)0xF000 + (ulong)TSS_SEL);   // 16-byte system descriptor
    // byte0-1 limit[15:0]; bits16-31 base[15:0]; byte4 base[23:16];
    // byte5 access(0x89); byte6 limit[19:16]; byte7 base[31:24]; dword2 base[63:32].
    uint lo = (limit & 0xFFFF) | ((uint)(base & 0xFFFF) << 16);
    uint hi = ((uint)((base >> 16) & 0xFF))
            | (0x89u << 8)                        // present | available 64-bit TSS
            | (((limit >> 16) & 0x0F) << 16)
            | (((uint)((base >> 24) & 0xFF)) << 24);
    g[0] = lo;
    g[1] = hi;
    g[2] = (uint)(base >> 32);
    g[3] = 0;
}

fn void umode_setup()
{
    // Rebuild the GDT in place at 0xF000 with the same kernel segments plus
    // user (DPL-3) segments and a TSS descriptor.
    gdt_put(0, 0, 0);              // null
    gdt_put(1, 0x0000FFFF, 0x00CF9A00);   // 0x08 code32
    gdt_put(2, 0x0000FFFF, 0x00CF9200);   // 0x10 data32
    gdt_put(3, 0x00000000, 0x00209A00);   // 0x18 code64  (kernel)
    gdt_put(4, 0x00000000, 0x00009200);   // 0x20 data64  (kernel)
    gdt_put(5, 0x00000000, 0x0020FA00);   // 0x28 user code64 (DPL 3)
    gdt_put(6, 0x00000000, 0x0000F200);   // 0x30 user data64 (DPL 3)

    for (int i = 0; i < 104; i++) { g_tss[i] = 0; }
    *(ulong*)(&g_tss[0] + 4) = UMODE_KSTACK;   // RSP0: kernel stack for ring-3 -> ring-0
    tss_put_desc((ulong)&g_tss[0], 0x67);      // 104-byte TSS
    xk_lgdt(0xF000, 0x4F);                     // 7*8 + 16 - 1 = 0x4F
    xk_ltr(TSS_SEL);

    // Make the 2 MiB user page at USER_BASE user-accessible (U/S). For ring-3
    // to reach it, EVERY level of the page-table walk needs U/S, so set it on
    // PML4[0], PDPT[0] and PDE[idx], then flush the TLB.
    *(uint*)((ulong)0x9000)        |= 0x4;   // PML4[0]
    *(uint*)((ulong)0xA000)        |= 0x4;   // PDPT[0]
    *(uint*)((ulong)0xB000 + (ulong)USER_PDE * 8) |= 0x4;   // PDE[idx]
    xk_reload_cr3();

    g_user_resume = (ulong)&umode_resume;
    xk_puts("[umode] ring-3 descriptor + TSS ready\r\n");
}

// Called once from boot; drops to ring 3 and does not return directly.
fn void umode_enter()
{
    uprog_init();
    for (int i = 0; i < USER_PROG_LEN; i++)
    {
        ((char*)USER_BASE)[i] = user_prog[i];
    }
    ulong user_sp = USER_BASE + 0x200000 - 16;
    xk_puts("[umode] entering ring 3...\r\n");
    xk_enter_ring3(USER_BASE, user_sp);
    // not reached
}

// Entered after the user program calls SYS_EXIT (called from the ring-0
// syscall handler). We skipped the ISR's iretq, so re-enable interrupts
// before running the normal desktop loop.
fn void umode_resume()
{
    xk_sti();   // re-enable interrupts (the syscall gate left them off)
    xk_puts("[umode] ring-3 program returned to ring 0\r\n");
    xk_idle_loop();
}