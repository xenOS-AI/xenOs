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

// Kernel's own identity page tables (built by stage2, 0..4GiB over 2MiB pages).
const ulong K_PML4 = 0x9000;
const ulong K_PDPT = 0xA000;
// Page-table entry flags for a fresh per-process address space.
const uint PTE_PRESENT_WRITE = 0x3;             // present | rw
const uint PTE_USER           = 0x4;            // user-accessible (U/S)
const uint PTE_2M_PAGE        = 0x80;           // 2MiB page (PS bit) on a PDE

char[104] g_tss;                        // raw 64-bit TSS (no struct padding)
ulong g_user_resume;                    // ring-0 address SYS_EXIT returns to

// xk_lgdt / xk_ltr / xk_read_cr3 are declared in xk_core.c3 (same module).
extern fn void xk_enter_ring3(ulong entry, ulong user_sp);
extern fn void xk_reload_cr3();
extern fn void xk_set_cr3(ulong value);

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

    // NOTE: we do NOT poke U/S bits into the shared kernel page tables here.
    // Every ring-3 program instead gets its OWN address space (distinct CR3)
    // built by create_process_addrspace(), so the kernel tables stay fully
    // supervisor-privileged. See umode_enter().
    g_user_resume = (ulong)&umode_resume;
    xk_puts("[umode] ring-3 descriptor + TSS ready\r\n");
}

// Build a fresh, independent address space (distinct CR3) for a user process:
// an identity 0..4GiB map over 2MiB pages (mirroring the kernel's stage2 map),
// where only the 2MiB page containing `user_base` is marked user-accessible and
// every other PDE is supervisor. PML4[0] and PDPT[] are U/S so the hardware page
// walk's privilege check passes for the user page (the supervisor PDEs below
// still block ring-3 from every other page). Returns the physical PML4 to load
// into CR3, or 0 if frames are exhausted.
fn ulong create_process_addrspace(ulong user_base)
{
    ulong pm4 = frame_alloc();
    ulong pdp = frame_alloc();
    ulong pd0 = frame_alloc();
    ulong pd1 = frame_alloc();
    ulong pd2 = frame_alloc();
    ulong pd3 = frame_alloc();
    if (pm4 == 0 || pdp == 0 || pd0 == 0 || pd1 == 0 || pd2 == 0 || pd3 == 0) return 0;
    kmemzero((void*)pm4, 4096);
    kmemzero((void*)pdp, 4096);
    kmemzero((void*)pd0, 4096);
    kmemzero((void*)pd1, 4096);
    kmemzero((void*)pd2, 4096);
    kmemzero((void*)pd3, 4096);

    ulong user_page = user_base & ~((ulong)0x1FFFFF);   // 2MiB-aligned user page

    // PML4[0] -> PDPT (present|rw|user so the walk clears the user check).
    *(uint*)(pm4) = (uint)(pdp & 0xFFFFF000) | (PTE_PRESENT_WRITE | PTE_USER);
    // PDPT[0..3] -> PD0..3, user-flag for the walk.
    ulong pd = pd0;
    *(uint*)(pdp + 0x00) = (uint)(pd0 & 0xFFFFF000) | (PTE_PRESENT_WRITE | PTE_USER);
    *(uint*)(pdp + 0x08) = (uint)(pd1 & 0xFFFFF000) | (PTE_PRESENT_WRITE | PTE_USER);
    *(uint*)(pdp + 0x10) = (uint)(pd2 & 0xFFFFF000) | (PTE_PRESENT_WRITE | PTE_USER);
    *(uint*)(pdp + 0x18) = (uint)(pd3 & 0xFFFFF000) | (PTE_PRESENT_WRITE | PTE_USER);

    // Fill each PD's 512 identity 2MiB PDEs; the user page's PDE gets U/S.
    for (int i = 0; i < 4; i++)
    {
        ulong gb_base = (ulong)i * 0x40000000;   // PD i covers [i GiB, i+1 GiB)
        for (int e = 0; e < 512; e++)
        {
            ulong phys = gb_base + (ulong)e * 0x200000;
            uint entry = (uint)(phys & 0xFFE00000) | PTE_PRESENT_WRITE | PTE_2M_PAGE;
            if (phys == user_page)
            {
                entry |= PTE_USER;
            }
            *(uint*)(pd + (ulong)e * 8) = entry;
        }
        if (i == 0) { pd = pd1; }
        else if (i == 1) { pd = pd2; }
        else if (i == 2) { pd = pd3; }
    }
    return pm4;
}

// Called once from boot; drops to ring 3 and does not return directly.
fn void umode_enter()
{
    uprog_init();
    for (int i = 0; i < USER_PROG_LEN; i++)
    {
        ((char*)USER_BASE)[i] = user_prog[i];
    }
    // Build an INDEPENDENT address space (distinct CR3) for this process and
    // switch to it before dropping to ring 3. The kernel tables stay untouched.
    ulong proc_cr3 = create_process_addrspace(USER_BASE);
    if (proc_cr3 == 0)
    {
        xk_puts("[umode] FAILED to allocate a process address space\r\n");
        return;
    }
    xk_set_cr3(proc_cr3);
    xk_puts("[umode] ring-3 process address space CR3=");
    xk_puthex(xk_read_cr3());
    xk_puts(" (kernel was 0x0000000000009000)\r\n");

    ulong user_sp = USER_BASE + 0x200000 - 16;
    xk_puts("[umode] entering ring 3 (distinct CR3)...\r\n");
    xk_enter_ring3(USER_BASE, user_sp);
    // not reached
}

// Entered after the user program calls SYS_EXIT (called from the ring-0
// syscall handler). We skipped the ISR's iretq, so switch BACK to the kernel
// address space, re-enable interrupts, then run the normal desktop loop.
fn void umode_resume()
{
    xk_set_cr3(K_PML4);     // back to the kernel's own identity address space
    xk_sti();               // re-enable interrupts (the syscall gate left them off)
    xk_puts("[umode] ring-3 program returned to ring 0 (kernel CR3 restored)\r\n");
    xk_idle_loop();
}