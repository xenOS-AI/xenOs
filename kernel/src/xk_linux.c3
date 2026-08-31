module xk;

// ============================================================================
// xenOS Linux userland: bundles a real (musl) Linux ELF executable, maps it
// with an ELF64 loader into a ring-3 process address space, and services its
// POSIX system calls through the genuine x86_64 SysV `syscall` instruction
// (entered via MSR LSTAR -> syscall_entry in asm_runtime.asm -> here).
//
// This turns xenOS's ring-3 support from a tiny hand-written demo into a
// place where actual, unmodified Linux ELF binaries run POSIX code. The load
// base for this milestone is the static non-PIE layout (segments at 0x400000)
// that `musl-gcc -static -no-pie` produces.
// ============================================================================

// ---- registers passed by the sysret ABI (from syscall_entry's saved block) ----
extern fn void   xk_linux_syscall_init();
extern fn ulong  xk_rdmsr(uint msr);
extern fn void   xk_wrmsr(uint msr, ulong value);
// xk_set_cr3 / xk_read_cr3 / xk_enter_ring3 are declared in xk_umode.c3 (same module).

// ---- user address-space layout (identity map: phys == vaddr) ----
const ulong LX_USER_START = 0x00400000;   // static non-PIE code/data base (4 MiB)
const ulong LX_HEAP_END   = 0x00A00000;   // user brk cap (10 MiB)
const ulong LX_STACK_TOP  = 0x0FF00000;   // user stack top (255 MiB; RAM is 0..256 MiB)
const ulong LX_MMAP_BASE  = 0x0C000000;   // anonymous mmap arena start (192 MiB)
const ulong LX_MMAP_END   = 0x0FC00000;   // arena end (252 MiB)

ulong g_linux_pml4;                       // this process's CR3
ulong g_user_brk;                         // program break (brk)
ulong g_mmap_cur = LX_MMAP_BASE;          // next anonymous mmap address
ulong g_linux_pid = 1;
ulong g_tid_addr = 0;

// Mask (on) or restore (off) the 8259 PIC IRQ lines. While a Linux ring-3
// process runs we keep every device IRQ masked so the PIT/keyboard/mouse
// cannot clobber a ring-0/3 transition (QEMU's iretq is fragile when an IRQ
// lands mid-iretq -> a torn CS=0x28 frame makes the ISR return #GP). We
// re-enable them as soon as the process exits back to the desktop.
fn void xk_mask_hw_irqs(int on)
{
    if (on)
    {
        xk_outb(0x21, (char)0xFF);   // mask all master IRQs
        xk_outb(0xA1, (char)0xFF);   // mask all slave IRQs
    }
    else
    {
        xk_outb(0x21, (char)0xF8);   // unmask timer(0), kbd(1), slave(2)
        xk_outb(0xA1, (char)0xEF);   // unmask mouse(12)
    }
}

// ---- ELF64 layout constants (offsets into the file / program header) ----
const uint ELF_E_TYPE   = 16;
const uint ELF_E_MACH   = 18;
const uint ELF_E_ENTRY  = 24;
const uint ELF_E_PHOFF  = 32;
const uint ELF_E_PHENTSZ= 54;
const uint ELF_E_PHNUM  = 56;
const uint PT_LOAD      = 1;
const uint PH_OFF_FLAGS = 4;
const uint PH_OFF_VADDR = 16;
const uint PH_OFF_FILESZ= 32;
const uint PH_OFF_MEMSZ = 40;
const uint PH_SIZE      = 56;
const uint EM_X86_64    = 62;

// ---- Linux errno (returned as negative values) ----
const long ENOMEM = 12;
const long ENOENT = 2;
const long EBADF  = 9;
const long EINVAL = 22;
const long ENOTTY = 25;
const long ENOSYS = 38;
const long EMFILE = 24;

fn uint rd_u16(char* b, uint off) { return (uint)((char)b[off]) | ((uint)((char)b[off+1]) << 8); }
fn uint rd_u32(char* b, uint off)
{
    return (uint)((char)b[off]) | ((uint)((char)b[off+1]) << 8)
         | ((uint)((char)b[off+2]) << 16) | ((uint)((char)b[off+3]) << 24);
}
fn ulong rd_u64(char* b, uint off)
{
    ulong v = 0;
    for (int i = 7; i >= 0; i--) { v = (v << 8) | (ulong)(uint)((char)b[off + (uint)i]); }
    return v;
}

// Mark the 2 MiB superpage containing `vaddr` as user-accessible (U/S bit) in
// the given process CR3 (identity hierarchy: pml4[0]->pdp->pd->pde).
fn void mark_user_pde(ulong pml4, ulong vaddr)
{
    ulong pdp = *(ulong*)pml4 & (ulong)0xFFFFF000;
    int pdidx = (int)((vaddr >> 30) & 0x1FF);
    ulong pd  = *(ulong*)(pdp + (ulong)pdidx * 8) & (ulong)0xFFFFF000;
    int pde   = (int)((vaddr >> 21) & 0x1FF);
    uint* ent = (uint*)(pd + (ulong)pde * 8);
    *ent = *ent | 0x4;                    // PTE_USER
}

// Write 8 bytes little-endian at `a` (byte-wise; avoids C3 pointer-cast quirks).
fn void st8(ulong a, ulong v)
{
    for (int i = 0; i < 8; i++)
    {
        ((char*)a)[i] = (char)((v >> (ulong)(i * 8)) & 0xFF);
    }
}

// ---- file-descriptor table (fd 0/1/2 are the standard stream slots) ----
const int MAX_FDS = 32;
struct LxFD { bool used; ulong buf; ulong len; ulong pos; }
LxFD[MAX_FDS] g_fd;

fn void linux_fd_init()
{
    for (int i = 0; i < MAX_FDS; i++) { g_fd[i].used = false; g_fd[i].buf = 0; g_fd[i].len = 0; g_fd[i].pos = 0; }
    g_fd[0].used = true;   // stdin
    g_fd[1].used = true;   // stdout
    g_fd[2].used = true;   // stderr
}

fn long lx_do_open(char* path, long flags)
{
    char* p = path;
    int guard = 0;
    while ((char)p[0] == '/' && guard < 16) { p++; guard++; }
    uint cap = 65536;
    char* buf = (char*)kmalloc(cap);
    if (buf == null) return -ENOMEM;
    uint outlen = 0;
    int r = fat_read_file(p, buf, cap, &outlen);
    if (r != 0) { kfree(buf); return -ENOENT; }
    int fdi = 0;
    for (fdi = 0; fdi < MAX_FDS; fdi++) { if (!g_fd[fdi].used) break; }
    if (fdi >= MAX_FDS) { kfree(buf); return -EMFILE; }
    g_fd[fdi].used = true;
    g_fd[fdi].buf = (ulong)buf;
    g_fd[fdi].len = (ulong)outlen;
    g_fd[fdi].pos = 0;
    return (long)fdi;
}

fn long lx_do_close(long fd)
{
    if (fd < 0 || fd >= MAX_FDS || !g_fd[fd].used || fd <= 2) return -EBADF;
    kfree((void*)g_fd[fd].buf);
    g_fd[fd].used = false;
    g_fd[fd].buf = 0;
    g_fd[fd].len = 0;
    g_fd[fd].pos = 0;
    return 0;
}

fn long lx_do_read(long fd, char* buf, ulong len)
{
    if (fd < 0 || fd >= MAX_FDS || !g_fd[fd].used) return -EBADF;
    if (fd == 0) return 0;                       // stdin: immediate EOF
    ulong pos  = g_fd[fd].pos;
    ulong l    = g_fd[fd].len;
    ulong avail = pos < l ? l - pos : 0;
    ulong n = len < avail ? len : avail;
    for (ulong i = 0; i < n; i++) { ((char*)(ulong)buf)[i] = ((char*)g_fd[fd].buf)[pos + i]; }
    g_fd[fd].pos = pos + n;
    return (long)n;
}

fn long lx_do_write(long fd, char* buf, ulong len)
{
    if (fd != 1 && fd != 2) return -EBADF;       // only stdout/stderr so far
    for (ulong i = 0; i < len; i++) { xk_serial_putc(((char*)(ulong)buf)[i]); }
    return (long)len;
}

struct Iovec { ulong base; ulong len; }
fn long lx_do_writev(long fd, ulong iov, int cnt)
{
    if (fd != 1 && fd != 2) return -EBADF;
    Iovec* v = (Iovec*)(ulong)iov;
    long total = 0;
    for (int i = 0; i < cnt; i++)
    {
        ulong base = v[i].base;
        ulong len  = v[i].len;
        if (len == 0) continue;
        for (ulong j = 0; j < len; j++) { xk_serial_putc(((char*)(ulong)base)[j]); }
        total += (long)len;
    }
    return total;
}

fn long lx_do_brk(ulong addr)
{
    if (addr == 0) return (long)g_user_brk;
    if (addr > LX_HEAP_END) return (long)g_user_brk;   // fail: return old break
    ulong p0 = g_user_brk & ~(ulong)0x1FFFFF;
    ulong p1 = addr & ~(ulong)0x1FFFFF;
    for (ulong pg = p0; pg <= p1; pg += (ulong)0x200000) { mark_user_pde(g_linux_pml4, pg); }
    g_user_brk = addr;
    return (long)g_user_brk;
}

fn long lx_do_mmap(ulong len)
{
    ulong want = (len + 4095) & ~((ulong)4095);
    if (want == 0) want = 4096;
    if (g_mmap_cur + want > LX_MMAP_END) return -ENOMEM;
    ulong v = g_mmap_cur;
    g_mmap_cur += want;
    for (ulong pg = v & ~(ulong)0x1FFFFF; pg <= (v + want) & ~(ulong)0x1FFFFF; pg += (ulong)0x200000)
    {
        mark_user_pde(g_linux_pml4, pg);
    }
    return (long)v;
}

const ulong ARCH_SET_GS = 0x1001;
const ulong ARCH_SET_FS = 0x1002;
const ulong ARCH_GET_FS = 0x1003;
const ulong ARCH_GET_GS = 0x1004;
const ulong TIOCGWINSZ  = 0x5413;

// ---- the Linux syscall dispatcher (called by syscall_entry in asm) ----
//   ulong xk_linux_dispatch(ulong nr, ulong* a)  -- a[0..5] = a1..a6 (sysV)
// A negative return is a Linux errno (musl negates it into errno). exit_group
// never returns (it resumes the desktop via umode_resume).
fn ulong xk_linux_dispatch(ulong nr, ulong* a) @export("xk_linux_dispatch")
{
    if (nr == 60 || nr == 231)                       // exit / exit_group
    {
        xk_puts("\\r\\n[linux] process exited (code=");
        xk_putdec((int)a[0]);
        xk_puts(") > returning to xenOS desktop\\r\\n");
        umode_resume();
        return 0;                                    // unreached
    }
    else if (nr == 1)       { return (ulong)lx_do_write((long)a[0], (char*)(ulong)a[1], a[2]); }
    else if (nr == 0)       { return (ulong)lx_do_read((long)a[0], (char*)(ulong)a[1], a[2]); }
    else if (nr == 2)       { return (ulong)lx_do_open((char*)(ulong)a[0], (long)a[1]); }
    else if (nr == 257)     { return (ulong)lx_do_open((char*)(ulong)a[1], (long)a[2]); }  // openat
    else if (nr == 3)       { return (ulong)lx_do_close((long)a[0]); }
    else if (nr == 20)      { return (ulong)lx_do_writev((long)a[0], a[1], (int)a[2]); }
    else if (nr == 12)      { return (ulong)lx_do_brk(a[0]); }
    else if (nr == 39)      { return g_linux_pid; }
    else if (nr == 218)     { g_tid_addr = a[0]; return g_linux_pid; }
    else if (nr == 16)      { return (ulong)(-ENOTTY); }            // ioctl (no tty)
    else if (nr == 9)       { return (ulong)lx_do_mmap(a[1]); }     // mmap (anonymous)
    else if (nr == 11)      { return 0; }                           // munmap
    else if (nr == 10)      { return 0; }                           // mprotect
    else if (nr == 158)     // arch_prctl (TLS FS/GS base)
    {
        ulong op = a[0];
        if (op == ARCH_SET_FS) { xk_wrmsr(0xC0000100, a[1]); return 0; }
        else if (op == ARCH_GET_FS) { ((ulong*)a[1])[0] = xk_rdmsr(0xC0000100); return 0; }
        else if (op == ARCH_SET_GS) { xk_wrmsr(0xC0000101, a[1]); return 0; }
        else if (op == ARCH_GET_GS) { ((ulong*)a[1])[0] = xk_rdmsr(0xC0000101); return 0; }
        return (ulong)(-EINVAL);
    }
    else if (nr == 228)     // clock_gettime (musl falls back here without a VDSO)
    {
        ulong ts = a[1];
        ulong tt = xk_get_ticks();                    // PIT ~100 Hz
        ((ulong*)ts)[0] = tt / 100;                   // tv_sec
        ((ulong*)ts)[1] = (tt % 100) * 10000000ul;    // tv_nsec
        return 0;
    }
    else if (nr == 96)      // gettimeofday
    {
        ulong tv = a[0];
        ulong tt = xk_get_ticks();
        ((ulong*)tv)[0] = tt / 100;
        ((ulong*)tv)[1] = 0;
        return 0;
    }
    else if (nr == 201)     // time
    {
        ulong tt = xk_get_ticks();
        if (a[0] != 0) { ((ulong*)a[0])[0] = tt / 100; }
        return tt / 100;
    }
    else if (nr == 14 || nr == 97 || nr == 15 || nr == 13) { return 0; } // rt_sig/signal stubs
    else if (nr == 5)       { return 0; }  // fstat (stub)
    // Unknown syscall: print which one, then ENOSYS (keeps musl's failure visible).
    xk_puts("[linux] unimplemented syscall nr=");
    xk_putdec((int)nr);
    xk_puts("\\r\\n");
    return (ulong)(-ENOSYS);
}

// ---- ELF64 static loader ----
fn bool linux_load_blob(char* bin, uint len, ulong* entry_out, ulong* stack_out)
{
    if (len < 64) { xk_puts("[linux] blob too small\\r\\n"); return false; }
    if ((char)bin[0] != (char)0x7F || (char)bin[1] != 'E' || (char)bin[2] != 'L' || (char)bin[3] != 'F')
    { xk_puts("[linux] bad ELF magic\\r\\n"); return false; }
    if ((char)bin[4] != (char)2 || (char)bin[5] != (char)1)
    { xk_puts("[linux] not ELF64 LE\\r\\n"); return false; }
    uint etype = rd_u16(bin, ELF_E_TYPE);
    uint emach = rd_u16(bin, ELF_E_MACH);
    if (etype != 2 && etype != 3) { xk_puts("[linux] not an executable ELF\\r\\n"); return false; }
    if (emach != EM_X86_64) { xk_puts("[linux] not x86-64\\r\\n"); return false; }
    ulong entry = rd_u64(bin, ELF_E_ENTRY);
    ulong phoff = rd_u64(bin, ELF_E_PHOFF);
    uint phent = rd_u16(bin, ELF_E_PHENTSZ);
    uint phnum = rd_u16(bin, ELF_E_PHNUM);
    if (phent != PH_SIZE) { xk_puts("[linux] unexpected phdr size\\r\\n"); return false; }

    g_linux_pml4 = create_process_addrspace(LX_USER_START);
    if (g_linux_pml4 == 0) { xk_puts("[linux] no frames for address space\\r\\n"); return false; }

    // mark the whole user code+heap region and the stack region U/S
    for (ulong v = LX_USER_START; v < LX_HEAP_END; v += (ulong)0x200000) { mark_user_pde(g_linux_pml4, v); }
    for (ulong v = (ulong)0x0FC00000; v < LX_STACK_TOP; v += (ulong)0x200000) { mark_user_pde(g_linux_pml4, v); }

    // map each PT_LOAD: copy file bytes, zero the BSS tail
    ulong brk_end = 0;
    for (uint i = 0; i < phnum; i++)
    {
        ulong ph = phoff + (ulong)i * PH_SIZE;
                if (rd_u32(bin, (uint)ph) != PT_LOAD) continue;
                ulong poff  = rd_u64(bin, (uint)(ph + 8));    // p_offset: file offset of the content
                ulong vaddr = rd_u64(bin, (uint)(ph + PH_OFF_VADDR));
                ulong filesz = rd_u64(bin, (uint)(ph + PH_OFF_FILESZ));
                ulong memsz  = rd_u64(bin, (uint)(ph + PH_OFF_MEMSZ));
                xk_puts("[linux]  load ");
                xk_puthex(vaddr);
                xk_puts(" +");
                xk_putdec((int)memsz);
                xk_puts("\r\n");
                for (ulong k = 0; k < filesz; k++) { ((char*)vaddr)[k] = bin[poff + k]; }
        if (memsz > filesz) { kmemzero((void*)(ulong)(vaddr + filesz), memsz - filesz); }
        if (vaddr + memsz > brk_end) brk_end = vaddr + memsz;
    }
    g_user_brk = (brk_end + 4095) & ~((ulong)4095);

    // build the initial user stack: argc/argv/envp/auxv (Linux SysV layout)
    ulong sp = LX_STACK_TOP;
    // strings live just below the pointer array (grow down)
    const char* PROG = "/UHELLO.EXE";
    int plen = 0;
    while (PROG[plen] != 0) plen++;
    sp -= (ulong)plen + 1;
    for (int i = 0; i < plen; i++) { ((char*)sp)[i] = PROG[i]; }
    ((char*)sp)[plen] = 0;
    ulong path_str = sp;
    // 16 random bytes for AT_RANDOM (stack canary)
    sp -= 16;
    for (int i = 0; i < 16; i++) { ((char*)sp)[i] = (char)((int)sp + i); }
    ulong random_ptr = sp;
    // auxv: write pairs downward from current sp, pre-computing into an array
    // (we push downward so each aux pair is written 16 bytes below the next)
    ulong[32] aux;
    int an = 0;
    aux[an++] = 3;   aux[an++] = LX_USER_START + phoff;   // AT_PHDR
    aux[an++] = 4;   aux[an++] = 56;                      // AT_PHENT
    aux[an++] = 5;   aux[an++] = (ulong)phnum;            // AT_PHNUM
    aux[an++] = 6;   aux[an++] = 4096;                    // AT_PAGESZ
    aux[an++] = 7;   aux[an++] = 0;                       // AT_BASE (static)
    aux[an++] = 9;   aux[an++] = entry;                   // AT_ENTRY
    aux[an++] = 25;  aux[an++] = random_ptr;              // AT_RANDOM
    aux[an++] = 11;  aux[an++] = g_linux_pid;             // AT_UID
    aux[an++] = 12;  aux[an++] = g_linux_pid;             // AT_EUID
    aux[an++] = 13;  aux[an++] = g_linux_pid;             // AT_GID
    aux[an++] = 14;  aux[an++] = g_linux_pid;             // AT_EGID
    aux[an++] = 0;   aux[an++] = 0;                       // terminator
    sp -= (ulong)an * 8;
    for (int i = 0; i < an; i++) { st8(sp + (ulong)i * 8, aux[i]); }
    // Align the ARRAY base down now so the argv/argc chain below lands with
    // argc on a 16-byte boundary == the final rsp. (32 bytes = 2*16, keeps rsp aligned.)
    sp = sp & ~((ulong)15);
    // envp (empty): one NULL
    sp -= 8; st8(sp, 0);
    // argv: [path, NULL]
    sp -= 8; st8(sp, 0);            // argv[1] = NULL
    sp -= 8; st8(sp, path_str);     // argv[0]
    // argc (this is the CPU entry rsp)
    sp -= 8; st8(sp, 1);

    linux_fd_init();
    *entry_out = entry;
    *stack_out = sp;
    return true;
}

// ---- boot entry: load + launch the embedded musl ELF, or fall back ----
fn void linux_boot_exec()
{
    linux_blob_init();     // fills the BSS blob from generated byte code
    xk_puts("[linux] enabling SYSCALL MSRs\r\n");
    xk_linux_syscall_init();
    ulong entry = 0;
    ulong stack = 0;
    if (linux_load_blob(&linux_blob[0], LINUX_BLOB_LEN, &entry, &stack))
    {
        xk_puts("[linux] launching musl ELF (entry=");
        xk_puthex(entry);
        xk_puts(" sp=");
        xk_puthex(stack);
        xk_puts(")\r\n");
        xk_mask_hw_irqs(1);      // keep device IRQs off while the ring-3 process runs
        xk_set_cr3(g_linux_pml4);
        xk_enter_ring3(entry, stack);
    }
    else
    {
        xk_puts("[linux] load failed; falling back to the native ring-3 demo\\r\\n");
        umode_enter();
    }
}