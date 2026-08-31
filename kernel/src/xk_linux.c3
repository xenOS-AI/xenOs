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
// iretq to ring-3 with a chosen rax/rflags (fork parent/child resume), and the
// user RSP captured at syscall entry.
extern fn void   xk_user_return(ulong rax_val, ulong entry, ulong user_rsp, ulong rflags);
extern fn ulong  xk_get_user_rsp();
// callee-saved-register snapshot (rbx,rbp,r12..r15) captured at syscall entry
extern fn ulong* xk_get_resume_snapshot();
extern fn void   xk_set_resume_block(ulong* p);
extern fn ulong  xk_rdmsr(uint msr);
extern fn void   xk_wrmsr(uint msr, ulong value);
// xk_set_cr3 / xk_read_cr3 / xk_enter_ring3 are declared in xk_umode.c3 (same module).

// ---- user address-space layout (identity map: phys == vaddr) ----
const ulong LX_USER_START = 0x00400000;   // static non-PIE code/data base (4 MiB)
const ulong LX_HEAP_END   = 0x00A00000;   // user brk cap (10 MiB)
const ulong LX_STACK_TOP  = 0x0FF00000;   // user stack top (255 MiB; RAM is 0..256 MiB)
const ulong LX_INTERP_BASE= 0x0A000000;   // ld-musl interpreter load base (160 MiB)
const ulong LX_MMAP_BASE  = 0x0C000000;   // anonymous mmap arena start (192 MiB)
const ulong LX_MMAP_END   = 0x0FC00000;   // arena end (252 MiB)

ulong g_linux_pml4;                       // this process's CR3
ulong g_user_brk;                         // program break (brk)
ulong g_mmap_cur = LX_MMAP_BASE;          // next anonymous mmap address
ulong g_linux_pid = 1;
ulong g_tid_addr = 0;
// ---- fork() state (Phase A.2: synchronous child-first fork) ----
// The kernel services ONE ring-3 process at a time. fork() clones the current
// process into a fresh, INDEPENDENT address space (distinct physical pages), runs
// the child synchronously to its exit, then resumes the suspended parent at the
// fork() return point with eax=child_pid. g_fork_pending selects which path an
// exit_group takes. (True concurrent preemption is the follow-on (Phase A.1).)
ulong g_next_pid_num  = 2;
bool  g_fork_pending  = false;
ulong g_fork_child_pid;
ulong g_saved_parent_pml4;
ulong g_saved_parent_brk;
ulong g_saved_parent_mmap;
ulong g_saved_parent_pid;
ulong g_saved_parent_rcx;
ulong g_saved_parent_r11;
ulong g_saved_parent_user_rsp;
ulong[12] g_parent_resume_regs;  // {a1..a6, rbx,rbp,r12..r15} frozen at fork() time

// ---- nil/errno constants used by the socket layer ----

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
const long EPIPE  = 32;
const long EAGAIN = 11;
const long ECONNREFUSED = 111;
const long EEXIST = 17;
const long ENOSPC = 28;
const long EISDIR = 21;

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
const uint FD_NONE = 0;
const uint FD_FILE = 1;
const uint FD_SOCK = 2;    // in-kernel byte-stream socket (AF_UNIX SOCK_STREAM)
const uint FD_EPOLL = 3;   // epoll interest-list fd
const uint FD_NULL  = 4;   // /dev/null
const uint FD_ZERO  = 5;   // /dev/zero
struct LxFD { bool used; uint type; ulong buf; ulong cap; ulong len; ulong pos; int peer;
              bool listener; char[24] spath; int[4] pending; uint pn; }
LxFD[MAX_FDS] g_fd;
LxFD[MAX_FDS] g_saved_parent_fds;   // snapshot taken at fork() to restore the parent

// ---- epoll sets (Phase A.4): per-epoll-fd interest list ----
const int MAX_EPOLL_SETS = 8;
const int MAX_EPOLL_ITEM = 32;
const uint EPOLL_CTL_ADD = 1;
const uint EPOLL_CTL_DEL = 2;
const uint EPOLL_CTL_MOD = 3;
struct EpollItem { bool used; int fd; uint events; ulong data; }
struct EpollSet { bool used; EpollItem[MAX_EPOLL_ITEM] items; }
EpollSet[MAX_EPOLL_SETS] g_epolls;
int[MAX_FDS] g_epoll_of;             // epfd -> set index (-1 = not an epoll fd)

// ---- concurrent user processes (Phase A.1) ----
// Cooperative scheduler: blocking syscalls park the current process and switch to
// another runnable one via up_switch_to (never hardware-PIT-preempts a ring-3 frame,
// which QEMU 11's iretq is fragile about). A parked process is re-dispatched fresh on
// wake (its abandoned kernel stack frame is never resumed and simply gets reused).
const int MAX_UPROC = 8;
struct UProc
{
    bool used;
    bool runnable;    // eligible to be scheduled
    bool parked;      // blocked mid-syscall -> re-dispatch (sys_nr/sys_a) on wake
    bool init;        // never run -> enter user at ret_rip with ret_rax
    ulong pid;
    ulong cr3;
    ulong brk;
    ulong mmap_cur;
    LxFD[MAX_FDS] fds;
    ulong ret_rax;
    ulong user_rsp;
    ulong ret_rip;        // rcx (user return RIP)
    ulong ret_rflags;     // r11
    ulong[12] regs;       // a1..a6 + callee (Linux ABI preserved set)
    ulong sys_nr;         // parked syscall to re-dispatch
    ulong[6] sys_a;
}
UProc[MAX_UPROC] g_up;
int g_cur_up = -1;           // index of the currently executing process
ulong g_disp_nr;             // syscall number of the in-flight syscall
ulong* g_disp_a;             // its syscall arg block (points at syscall_kstack)

// ---- shared socket state (Phase A.1) ----
// Socket rings/queues must be SHARED across processes (a client in one process and a
// compositor in another share the same socket). So all dynamic socket state lives in
// this GLOBAL table (indexed by fd), NOT in the per-process fd table which is copied
// on fork. Only g_fd[fd].used/.type route I/O from the copied tables.
const int SOCK_CAP = 4096;
struct SockState
{
    bool used;
    ulong buf;       // kernel-heap ring (peer-fed on write, drained on read)
    ulong cap;
    ulong len;       // bytes buffered
    ulong pos;       // ring read head
    int peer;        // peer fd (-1 if none / peer closed)
    bool listener;
    char[24] spath;
    int[4] pending;
    uint pn;
}
SockState[MAX_FDS] g_sock;

fn void linux_fd_init()
{
    for (int i = 0; i < MAX_FDS; i++) { g_fd[i].used = false; g_fd[i].type = FD_NONE; g_fd[i].buf = 0; g_fd[i].cap = 0; g_fd[i].len = 0; g_fd[i].pos = 0; g_fd[i].peer = -1; g_fd[i].listener = false; g_fd[i].pn = 0; g_fd[i].spath[0] = 0; g_epoll_of[i] = -1; }
    for (int i = 0; i < MAX_EPOLL_SETS; i++) { g_epolls[i].used = false; for (int k = 0; k < MAX_EPOLL_ITEM; k++) { g_epolls[i].items[k].used = false; } }
    for (int i = 0; i < MAX_FDS; i++) { g_sock[i].used = false; g_sock[i].peer = -1; g_sock[i].listener = false; g_sock[i].pn = 0; g_sock[i].buf = 0; g_sock[i].spath[0] = 0; }
    g_fd[0].used = true; g_fd[0].type = FD_FILE;   // stdin
    g_fd[1].used = true; g_fd[1].type = FD_FILE;   // stdout
    g_fd[2].used = true; g_fd[2].type = FD_FILE;   // stderr
}

// ---- AF_UNIX socketpair (Phase A.4: in-kernel byte-stream transport). This is
// the transport a future Wayland compositor/client pair will run over; for now a
// single process can socketpair(AF_UNIX, SOCK_STREAM, 0, sv) and talk to itself
// across the two descriptors. Buffers are kernel-heap rings; reads consume bytes,
// writes append. A writer returns -EPIPE once the peer descriptor is closed.
fn long lx_sock_write(long fd, char* buf, ulong len)
{
    // socketpair semantics: bytes written to one endpoint are received at the
    // peer, so a write appends to the PEER's receive queue (shared global state).
    int peer = g_sock[(int)fd].peer;
    if (peer < 0 || peer >= MAX_FDS || !g_sock[peer].used) return (long)(-EPIPE);
    SockState* s = &g_sock[peer];
    ulong written = 0;
    while (written < len)
    {
        if (s.len >= s.cap) break;                 // ring full: return partial
        ulong tail = (s.pos + s.len) % s.cap;
        ((char*)(ulong)s.buf)[tail] = ((char*)(ulong)buf)[written];
        s.len++;
        written++;
    }
    up_wake_all();                                 // wake any process blocked reading this
    return (long)written;
}

fn long lx_sock_read(long fd, char* buf, ulong len)
{
    SockState* s = &g_sock[(int)fd];
    if (s.len == 0)
    {
        // blocking read: park and let another process run; re-dispatched when woken
        if (up_park()) return 0;                   // switched (unreachable)
        return (long)(-EAGAIN);                    // nobody else runnable: caller retries
    }
    ulong got = 0;
    while (got < len && s.len > 0)
    {
        ((char*)(ulong)buf)[got] = ((char*)(ulong)s.buf)[s.pos];
        s.pos = (s.pos + 1) % s.cap;
        s.len--;
        got++;
    }
    return (long)got;
}

// socketpair(domain, type, protocol, int sv[2])  -- nr 53
fn long lx_sockpair(ulong* a)
{
    if ((long)a[0] != 1) return (long)(-EINVAL);     // AF_UNIX only
    int f1 = -1; int f2 = -1;
    for (int i = 3; i < MAX_FDS; i++) { if (!g_fd[i].used) { f1 = i; break; } }
    for (int i = (f1 < 0 ? 3 : f1 + 1); i < MAX_FDS; i++) { if (!g_fd[i].used) { f2 = i; break; } }
    if (f1 < 0 || f2 < 0) return (long)(-EMFILE);
    char* b1 = (char*)kmalloc(SOCK_CAP);
    char* b2 = (char*)kmalloc(SOCK_CAP);
    if (b1 == null || b2 == null) { if (b1 != null) kfree((void*)b1); if (b2 != null) kfree((void*)b2); return (long)(-ENOMEM); }
    g_fd[f1].used = true; g_fd[f1].type = FD_SOCK;
    g_fd[f2].used = true; g_fd[f2].type = FD_SOCK;
    g_sock[f1].used = true; g_sock[f1].buf = (ulong)b1; g_sock[f1].cap = SOCK_CAP; g_sock[f1].len = 0; g_sock[f1].pos = 0; g_sock[f1].peer = f2; g_sock[f1].listener = false; g_sock[f1].pn = 0; g_sock[f1].spath[0] = 0;
    g_sock[f2].used = true; g_sock[f2].buf = (ulong)b2; g_sock[f2].cap = SOCK_CAP; g_sock[f2].len = 0; g_sock[f2].pos = 0; g_sock[f2].peer = f1; g_sock[f2].listener = false; g_sock[f2].pn = 0; g_sock[f2].spath[0] = 0;
    ulong sv = a[3];
    if (sv != 0)
    {
        ((char*)(ulong)sv)[0] = (char)(f1 & 0xFF);       ((char*)(ulong)sv)[1] = (char)((f1 >> 8) & 0xFF);
        ((char*)(ulong)sv)[2] = (char)((f1 >> 16) & 0xFF); ((char*)(ulong)sv)[3] = (char)((f1 >> 24) & 0xFF);
        ((char*)(ulong)sv)[4] = (char)(f2 & 0xFF);       ((char*)(ulong)sv)[5] = (char)((f2 >> 8) & 0xFF);
        ((char*)(ulong)sv)[6] = (char)((f2 >> 16) & 0xFF); ((char*)(ulong)sv)[7] = (char)((f2 >> 24) & 0xFF);
    }
    xk_puts("[sock] socketpair(AF_UNIX) -> fds ");
    xk_putdec(f1); xk_puts(" "); xk_putdec(f2); xk_puts("\r\n");
    return 0;
}

// ---- AF_UNIX named server sockets (Phase A.4): the Wayland display-socket model ----
// All dynamic socket state (rings, listener accept-queue, bound path) lives in the
// SHARED g_sock table so a listener in one process and a client in another really
// communicate. Only g_fd[fd].used/.type are copied per-process (for I/O routing).
fn bool sockaddr_un_path(ulong sa, char* out, uint max)
{
    char* p = (char*)(ulong)sa;
    uint fam = (uint)(((char*)p)[0]) | ((uint)(((char*)p)[1]) << 8);
    if (fam != 1) return false;
    uint i = 0;
    while (i < max - 1)
    {
        char c = ((char*)(ulong)sa)[2 + i];
        out[i] = c;
        if (c == 0) return true;
        i++;
    }
    out[i] = 0;
    return true;
}

fn bool sock_fd(long fd)
{
    return fd >= 0 && fd < MAX_FDS && g_fd[(int)fd].used && g_fd[(int)fd].type == FD_SOCK;
}

fn bool sock_path_eq(char* a, char* b)
{
    int i = 0;
    while (a[i] != 0 && b[i] != 0) { if (a[i] != b[i]) return false; i++; }
    return a[i] == b[i];
}

// socket(domain, type, protocol) -- nr 41
fn long lx_socket(ulong* a)
{
    if ((long)a[0] != 1) return (long)(-EINVAL);     // AF_UNIX only
    int fdi = -1;
    for (int i = 3; i < MAX_FDS; i++) { if (!g_fd[i].used) { fdi = i; break; } }
    if (fdi < 0) return (long)(-EMFILE);
    g_fd[fdi].used = true; g_fd[fdi].type = FD_SOCK;
    g_sock[fdi].used = true; g_sock[fdi].peer = -1; g_sock[fdi].listener = false; g_sock[fdi].pn = 0;
    g_sock[fdi].buf = 0; g_sock[fdi].cap = SOCK_CAP; g_sock[fdi].len = 0; g_sock[fdi].pos = 0; g_sock[fdi].spath[0] = 0;
    return (long)fdi;
}

// bind(fd, sockaddr_un*, addrlen) -- nr 49
fn long lx_bind(ulong* a)
{
    long fd = (long)a[0];
    if (!sock_fd(fd)) return (long)(-EBADF);
    if (!sockaddr_un_path(a[1], &g_sock[(int)fd].spath[0], 24)) return (long)(-EINVAL);
    g_sock[(int)fd].listener = true;                // bound; becomes a listen candidate
    return 0;
}

// listen(fd, backlog) -- nr 50
fn long lx_listen(ulong* a)
{
    long fd = (long)a[0];
    if (!sock_fd(fd)) return (long)(-EBADF);
    g_sock[(int)fd].listener = true;
    return 0;
}

// connect(fd, sockaddr_un*, addrlen) -- nr 42
fn long lx_connect(ulong* a)
{
    long cfd = (long)a[0];
    if (!sock_fd(cfd)) return (long)(-EBADF);
    char[24] p;                                  // filled by sockaddr_un_path()
    if (!sockaddr_un_path(a[1], &p[0], 24)) return (long)(-EINVAL);
    int srv = -1;
    for (int i = 3; i < MAX_FDS; i++)
    {
        if (g_fd[i].used && g_fd[i].type == FD_SOCK && g_sock[i].listener && sock_path_eq(&g_sock[i].spath[0], &p[0])) { srv = i; break; }
    }
    if (srv < 0) return (long)(-ECONNREFUSED);
    if (g_sock[srv].pn >= 4) return (long)(-EMFILE);
    int e = -1;
    for (int i = 3; i < MAX_FDS; i++) { if (!g_fd[i].used) { e = i; break; } }
    if (e < 0) return (long)(-EMFILE);
    char* b1 = (char*)kmalloc(SOCK_CAP);
    char* b2 = (char*)kmalloc(SOCK_CAP);
    if (b1 == null || b2 == null) { if (b1 != null) kfree((void*)b1); if (b2 != null) kfree((void*)b2); return (long)(-ENOMEM); }
    g_fd[(int)cfd].type = FD_SOCK;
    g_sock[(int)cfd].used = true; g_sock[(int)cfd].buf = (ulong)b1; g_sock[(int)cfd].cap = SOCK_CAP; g_sock[(int)cfd].len = 0; g_sock[(int)cfd].pos = 0; g_sock[(int)cfd].peer = e; g_sock[(int)cfd].listener = false;
    g_fd[e].used = true; g_fd[e].type = FD_SOCK;
    g_sock[e].used = true; g_sock[e].buf = (ulong)b2; g_sock[e].cap = SOCK_CAP; g_sock[e].len = 0; g_sock[e].pos = 0; g_sock[e].peer = (int)cfd; g_sock[e].listener = false; g_sock[e].pn = 0; g_sock[e].spath[0] = 0;
    g_sock[srv].pending[g_sock[srv].pn++] = e;          // E waits in the listener's accept queue
    return 0;
}

// accept(fd, sockaddr*, *addrlen) -- nr 43 (non-blocking for now)
fn long lx_accept(ulong* a)
{
    long fd = (long)a[0];
    if (!sock_fd(fd)) return (long)(-EBADF);
    if (g_sock[(int)fd].pn == 0) return (long)(-EAGAIN);
    int e = g_sock[(int)fd].pending[0];
    for (uint i = 1; i < g_sock[(int)fd].pn; i++) { g_sock[(int)fd].pending[i - 1] = g_sock[(int)fd].pending[i]; }
    g_sock[(int)fd].pn--;
    return (long)e;
}

// ---- poll/ppoll (nr 7/271): event readability of the socket layer ----
const ushort POLLIN  = 0x001;
const ushort POLLOUT = 0x004;
const ushort POLLERR = 0x008;
const ushort POLLHUP = 0x010;
const ushort POLLNVAL= 0x020;

fn bool sock_readable(SockState* s)
{
    return s.len > 0 || (s.listener && s.pn > 0);   // data waiting, or a pending accept
}
fn bool sock_writable(SockState* s)
{
    return s.peer >= 0 && s.peer < MAX_FDS && g_sock[s.peer].used;   // peer still open
}

// poll(struct pollfd *fds, nfds, timeout_ms). Each pollfd is {int fd; short
// events; short revents}. Immediate readiness (no blocking yet -- returns what is
// ready now; timeout is ignored). Returns the number of ready descriptors.
fn long lx_poll(ulong* a)
{
    ulong fds = a[0];
    long nfds = (long)a[1];
    if (nfds < 0 || nfds > 1024) return (long)(-EINVAL);
    long ready = 0;
    for (long i = 0; i < nfds; i++)
    {
        ulong pf = fds + (ulong)i * 8;
        int fd = (int)(((char*)pf)[0]) | ((int)(((char*)pf)[1]) << 8)
               | ((int)(((char*)pf)[2]) << 16) | ((int)(((char*)pf)[3]) << 24);
        ushort rev = 0;
        if (fd >= 0 && fd < MAX_FDS && g_fd[fd].used)
        {
            if (g_fd[fd].type == FD_SOCK)
            {
                if (sock_readable(&g_sock[fd])) rev = (ushort)(rev | POLLIN);
                if (sock_writable(&g_sock[fd])) rev = (ushort)(rev | POLLOUT);
            }
            else if (g_fd[fd].type == FD_FILE) { rev = (ushort)(POLLIN | POLLOUT); }
            else { rev = POLLNVAL; }
        }
        else { rev = POLLNVAL; }
        ((char*)pf)[6] = (char)(rev & 0xFF);
        ((char*)pf)[7] = (char)((rev >> 8) & 0xFF);
        if (rev != 0) ready++;
    }
    return ready;
}

// ---- epoll (Phase A.4): the compositor's main loop ----
// fd_ready_events(LxFD*) reuses the poll readiness predicate.
fn uint fd_ready_events(int fd)
{
    if (g_fd[fd].type == FD_SOCK)
    {
        uint r = 0;
        if (sock_readable(&g_sock[fd])) r |= (uint)POLLIN;
        if (sock_writable(&g_sock[fd])) r |= (uint)POLLOUT;
        return r;
    }
    if (g_fd[fd].type == FD_FILE) return (uint)(POLLIN | POLLOUT);
    return (uint)POLLERR;
}

// epoll_create1(flags) -- nr 291
fn long lx_epoll_create1(ulong* a)
{
    int si = -1;
    for (int i = 0; i < MAX_EPOLL_SETS; i++) { if (!g_epolls[i].used) { si = i; break; } }
    if (si < 0) return (long)(-EMFILE);
    int fdi = -1;
    for (int i = 3; i < MAX_FDS; i++) { if (!g_fd[i].used) { fdi = i; break; } }
    if (fdi < 0) return (long)(-EMFILE);
    g_epolls[si].used = true;
    for (int k = 0; k < MAX_EPOLL_ITEM; k++) { g_epolls[si].items[k].used = false; }
    g_fd[fdi].used = true; g_fd[fdi].type = FD_EPOLL; g_fd[fdi].buf = 0; g_fd[fdi].cap = 0;
    g_fd[fdi].len = 0; g_fd[fdi].pos = 0; g_fd[fdi].peer = -1; g_fd[fdi].listener = false; g_fd[fdi].pn = 0;
    g_epoll_of[fdi] = si;
    return (long)fdi;
}

// epoll_ctl(epfd, op, fd, struct epoll_event*) -- nr 233
// struct epoll_event = { u32 events @0; pad; u64 data @8 } (16 bytes).
fn long lx_epoll_ctl(ulong* a)
{
    int epfd = (int)a[0]; int op = (int)a[1]; int fd = (int)a[2]; ulong ev = a[3];
    if (!(epfd >= 0 && epfd < MAX_FDS && g_fd[epfd].used && g_fd[epfd].type == FD_EPOLL)) return (long)(-EBADF);
    int si = g_epoll_of[epfd];
    if (si < 0 || !g_epolls[si].used) return (long)(-EBADF);
    int found = -1;
    for (int i = 0; i < MAX_EPOLL_ITEM; i++)
    {
        if (g_epolls[si].items[i].used && g_epolls[si].items[i].fd == fd) { found = i; break; }
    }
    if (op == (int)EPOLL_CTL_DEL)
    {
        if (found < 0) return (long)(-ENOENT);
        g_epolls[si].items[found].used = false;
        return 0;
    }
    // read events(4@ev+0) and data(8@ev+4). musl's struct epoll_event is PACKED:
    // sizeof=12, data at offset 4 (NOT the 16-byte glibc layout). Kernel must use
    // the same packed layout the test program compiles with.
    uint evmask = (uint)(((char*)ev)[0]) | ((uint)(((char*)ev)[1]) << 8)
                | ((uint)(((char*)ev)[2]) << 16) | ((uint)(((char*)ev)[3]) << 24);
    ulong data = 0;
    for (int i = 7; i >= 0; i--) { data = (data << 8) | (ulong)(uint)(((char*)ev)[4 + i]); }
    if (op == (int)EPOLL_CTL_ADD)
    {
        if (found >= 0) return (long)(-EEXIST);
        int slot = -1;
        for (int i = 0; i < MAX_EPOLL_ITEM; i++) { if (!g_epolls[si].items[i].used) { slot = i; break; } }
        if (slot < 0) return (long)(-ENOSPC);
        g_epolls[si].items[slot].used = true; g_epolls[si].items[slot].fd = fd;
        g_epolls[si].items[slot].events = evmask; g_epolls[si].items[slot].data = data;
        return 0;
    }
    if (op == (int)EPOLL_CTL_MOD)
    {
        if (found < 0) return (long)(-ENOENT);
        g_epolls[si].items[found].events = evmask; g_epolls[si].items[found].data = data;
        return 0;
    }
    return (long)(-EINVAL);
}

// epoll_wait(epfd, struct epoll_event*, maxevents, timeout) -- nr 232 (immediate)
fn long lx_epoll_wait(ulong* a)
{
    int epfd = (int)a[0]; ulong out = a[1]; long maxev = (long)a[2];
    if (!(epfd >= 0 && epfd < MAX_FDS && g_fd[epfd].used && g_fd[epfd].type == FD_EPOLL)) return (long)(-EBADF);
    int si = g_epoll_of[epfd];
    if (si < 0 || !g_epolls[si].used) return (long)(-EBADF);
    long n = 0;
    for (int i = 0; i < MAX_EPOLL_ITEM && n < maxev; i++)
    {
        if (!g_epolls[si].items[i].used) continue;
        int fd = g_epolls[si].items[i].fd;
        uint interest = g_epolls[si].items[i].events;
        uint eff = 0;
        if (fd >= 0 && fd < MAX_FDS && g_fd[fd].used) { eff = fd_ready_events(fd) & interest; }
        else { eff = (uint)(POLLERR & interest); }
        if (eff != 0)
        {
            ulong base = out + (ulong)n * 12;    // packed epoll_event (12 bytes)
            ((char*)base)[0] = (char)(eff & 0xFF); ((char*)base)[1] = (char)((eff >> 8) & 0xFF);
            ((char*)base)[2] = (char)((eff >> 16) & 0xFF); ((char*)base)[3] = (char)((eff >> 24) & 0xFF);
            st8(base + 4, g_epolls[si].items[i].data);
            n++;
        }
    }
    return n;
}

// ---- Phase A.6: minimal virtual filesystem (devfs) ----
// Virtual paths (no real mounts yet) the display stack opens/stat/accesses daily:
//   /dev/null, /dev/zero                -> in-kernel char devices
//   /dev, /dev/shm, /run, /tmp, /proc, /proc/self -> virtual directories
//   /proc/version|meminfo|cpuinfo|uptime|self/*   -> stub text files
// Anything else falls through to the real FAT16 volume.
const int VF_UNKNOWN = 0;
const int VF_NULL    = 1;
const int VF_ZERO    = 2;
const int VF_DIR     = 3;
const int VF_PROC    = 4;

fn bool xk_streq_ci(char* a, char* b)
{
    int i = 0;
    while (a[i] != 0 && b[i] != 0)
    {
        char ca = a[i]; char cb = b[i];
        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca + 32);
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb + 32);
        if (ca != cb) return false;
        i++;
    }
    return a[i] == b[i];
}

fn bool xk_startswith(char* a, char* pre)
{
    int i = 0;
    while (pre[i] != 0) { if (a[i] != pre[i]) return false; i++; }
    return true;
}

fn int vf_classify(char* p)   // `p` has leading '/' already stripped
{
    if (xk_streq_ci(p, "dev/null")) return VF_NULL;
    if (xk_streq_ci(p, "dev/zero")) return VF_ZERO;
    if (xk_streq_ci(p, "dev") || xk_streq_ci(p, "dev/shm") || xk_streq_ci(p, "run")
        || xk_streq_ci(p, "tmp") || xk_streq_ci(p, "proc") || xk_streq_ci(p, "proc/self")) return VF_DIR;
    if (xk_startswith(p, "proc/")) return VF_PROC;
    return VF_UNKNOWN;
}

// Fill a kernel buffer with a stub /proc file's text; returns bytes written.
fn ulong proc_stub_fill(char* name, char* out, uint cap)
{
    char* s = "proc stub\n";
    if (xk_startswith(name, "proc/version")) { s = "Linux version 0.0.0-xenOS (purist)\n"; }
    else if (xk_startswith(name, "proc/cpuinfo")) { s = "processor\t: 0\nvendor_id\t: xenOS\n"; }
    else if (xk_startswith(name, "proc/meminfo")) { s = "MemTotal:       262144 kB\n"; }
    else if (xk_startswith(name, "proc/uptime")) { s = "0.00 0.00\n"; }
    else if (xk_startswith(name, "proc/self/")) { s = "self-stub\n"; }
    uint i = 0;
    while (s[i] != 0 && i < cap - 1) { out[i] = s[i]; i++; }
    out[i] = 0;
    return (ulong)i;
}

fn long lx_do_open(char* path, long flags)
{
    char* p = path;
    int guard = 0;
    while ((char)p[0] == '/' && guard < 16) { p++; guard++; }
    int vf = vf_classify(p);
    if (vf == VF_NULL || vf == VF_ZERO)
    {
        int fdi = 0;
        for (fdi = 0; fdi < MAX_FDS; fdi++) { if (!g_fd[fdi].used) break; }
        if (fdi >= MAX_FDS) return (long)(-EMFILE);
        g_fd[fdi].used = true; g_fd[fdi].type = (vf == VF_NULL) ? FD_NULL : FD_ZERO;
        g_fd[fdi].buf = 0; g_fd[fdi].len = 0; g_fd[fdi].pos = 0; g_fd[fdi].peer = -1;
        return (long)fdi;
    }
    if (vf == VF_DIR) return (long)(-EISDIR);
    if (vf == VF_PROC)
    {
        uint cap2 = 512;
        char* buf = (char*)kmalloc(cap2);
        if (buf == null) return (long)(-ENOMEM);
        ulong n = proc_stub_fill(p, buf, cap2);
        int fdi = 0;
        for (fdi = 0; fdi < MAX_FDS; fdi++) { if (!g_fd[fdi].used) break; }
        if (fdi >= MAX_FDS) { kfree((void*)buf); return (long)(-EMFILE); }
        g_fd[fdi].used = true; g_fd[fdi].type = FD_FILE;
        g_fd[fdi].buf = (ulong)buf; g_fd[fdi].len = n; g_fd[fdi].pos = 0; g_fd[fdi].peer = -1;
        return (long)fdi;
    }
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
    g_fd[fdi].type = FD_FILE;
    g_fd[fdi].buf = (ulong)buf;
    g_fd[fdi].len = (ulong)outlen;
    g_fd[fdi].pos = 0;
    g_fd[fdi].peer = -1;
    g_fd[fdi].listener = false;
    g_fd[fdi].pn = 0;
    return (long)fdi;
}

fn long lx_do_close(long fd)
{
    if (fd < 0 || fd >= MAX_FDS || !g_fd[fd].used || fd <= 2) return -EBADF;
    if (g_fd[fd].type == FD_SOCK)
    {
        kfree((void*)g_sock[fd].buf);
        int peer = g_sock[fd].peer;
        if (peer >= 0 && peer < MAX_FDS && g_sock[peer].used) { g_sock[peer].peer = -1; }
        g_sock[fd].used = false;
    }
    else if (g_fd[fd].type == FD_EPOLL)
    {
        int si = g_epoll_of[fd];
        if (si >= 0 && si < MAX_EPOLL_SETS) { g_epolls[si].used = false; }
        g_epoll_of[fd] = -1;
    }
    else
    {
        kfree((void*)g_fd[fd].buf);
    }
    g_fd[fd].used = false;
    g_fd[fd].type = FD_NONE;
    g_fd[fd].buf = 0;
    g_fd[fd].cap = 0;
    g_fd[fd].len = 0;
    g_fd[fd].pos = 0;
    g_fd[fd].peer = -1;
    g_fd[fd].listener = false;
    g_fd[fd].pn = 0;
    g_fd[fd].spath[0] = 0;
    return 0;
}

fn long lx_do_read(long fd, char* buf, ulong len)
{
    if (fd < 0 || fd >= MAX_FDS || !g_fd[fd].used) return -EBADF;
    if (g_fd[fd].type == FD_SOCK) return lx_sock_read(fd, buf, len);
    if (g_fd[fd].type == FD_NULL) return 0;                       // /dev/null: EOF
    if (g_fd[fd].type == FD_ZERO)                                  // /dev/zero: NULs
    {
        for (ulong i = 0; i < len; i++) { ((char*)(ulong)buf)[i] = 0; }
        return (long)len;
    }
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
    if (fd < 0 || fd >= MAX_FDS || !g_fd[fd].used) return -EBADF;
    if (g_fd[fd].type == FD_SOCK) return lx_sock_write(fd, buf, len);
    if (g_fd[fd].type == FD_NULL || g_fd[fd].type == FD_ZERO) return (long)len;   // discard
    if (fd != 1 && fd != 2) return -EBADF;       // only stdout/stderr for files
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

// ---- Phase A.2: fork() -- clone into an independent address space ----
// Read the value of the 2 MiB PDE covering `va` in a process CR3 (identity
// hierarchy: pml4[0]->pdp->pd->pde). Returns the raw 64-bit PDE entry.
fn ulong xk_walk_pde(ulong pml4, ulong va)
{
    ulong pdp = *(ulong*)pml4 & 0xFFFFF000ul;
    int pdix = (int)((va >> 30) & 0x1FF);
    ulong pd  = *(ulong*)(pdp + (ulong)pdix * 8) & 0xFFFFF000ul;
    int pdi  = (int)((va >> 21) & 0x1FF);
    return (ulong)(*(uint*)(pd + (ulong)pdi * 8));
}

// Give `dst` an INDEPENDENT copy of the user page `slot` (2 MiB-aligned) that
// `src` maps. The child's fresh copy lives in newly allocated 4 KiB frames (the
// child must NOT share physical pages with the parent, or the child's writes
// would corrupt the parent's suspended view). The dst PDE for the slot is rebuilt
// as a pointer to a 4 KiB PTE table (dropping the 2 MiB superpage). Only slots
// present AND user-accessible in src are copied; kernel-owned slots keep dst's
// default identity map. Returns false if frames run out.
fn bool xk_copy_slot(ulong dst_pml4, ulong src_pml4, ulong slot)
{
    ulong ent = xk_walk_pde(src_pml4, slot);
    if ((ent & 1) == 0) return true;          // not present: nothing to copy
    if ((ent & 0x4) == 0) return true;        // not a USER page: keep dst identity
    ulong pt = frame_alloc();
    if (pt == 0) return false;
    kmemzero((void*)pt, 4096);                // fresh PTE table
    ulong dpdp = *(ulong*)dst_pml4 & 0xFFFFF000ul;
    int dpdix = (int)((slot >> 30) & 0x1FF);
    ulong dpd  = *(ulong*)(dpdp + (ulong)dpdix * 8) & 0xFFFFF000ul;
    int dpde  = (int)((slot >> 21) & 0x1FF);
    // Allocate 512 fresh 4 KiB frames and copy the source slot into them.
    for (int i = 0; i < 512; i++)
    {
        ulong f = frame_alloc();
        if (f == 0) return false;
        ulong src_phys = slot + (ulong)i * 4096;    // parent's identity page
        for (int k = 0; k < 4096; k++) { ((char*)f)[k] = ((char*)src_phys)[k]; }
        st8(pt + (ulong)i * 8, (f & 0xFFFFF000ul) | 0x7ul);   // present|rw|user leaf
    }
    *(uint*)(dpd + (ulong)dpde * 8) = (uint)(pt & 0xFFFFF000) | 0x7;  // PDE -> PTE table
    return true;
}

// Copy every user page in [LX_USER_START, LX_STACK_TOP) from `src` into `dst`.
fn bool xk_copy_user_region(ulong dst_pml4, ulong src_pml4)
{
    for (ulong slot = LX_USER_START; slot < LX_STACK_TOP; slot += (ulong)0x200000)
    {
        if (!xk_copy_slot(dst_pml4, src_pml4, slot)) return false;
    }
    return true;
}

// fork(): the dispatcher's arg block is a1..a6 then the syscall-entry return
// RIP (a[6]) and RFLAGS (a[7]); the user RSP is captured at entry. We snapshot
// the parent's whole state, clone it into an independent address space, switch
// to the child and enter it at the parent's return point with eax=0. The child
// runs; its exit_group resumes the parent (eax=child_pid).
fn long lx_fork(ulong* a)
{
    // Register a runnable CHILD process: a full clone of the current one that will
    // run via the cooperative scheduler when the parent blocks/exits. The child
    // inherits the parent's fork-time register set and address space (independent
    // physical copy), and first enters user code at fork()'s return with eax=0.
    int cs = -1;
    for (int i = 0; i < MAX_UPROC; i++) { if (!g_up[i].used) { cs = i; break; } }
    if (cs < 0) { xk_puts("[fork] no proc slots\r\n"); return (long)(-EMFILE); }
    ulong child_cr3 = create_process_addrspace(LX_USER_START);
    if (child_cr3 == 0) { xk_puts("[fork] no frames for child address space\r\n"); return (long)(-ENOMEM); }
    if (!xk_copy_user_region(child_cr3, g_linux_pml4))
    {
        xk_puts("[fork] ENOMEM copying user region\r\n");
        return (long)(-ENOMEM);
    }
    ulong child_pid = g_next_pid_num++;
    ulong* rs = xk_get_resume_snapshot();
    g_up[cs].used = true; g_up[cs].runnable = true; g_up[cs].parked = false; g_up[cs].init = true;
    g_up[cs].pid = child_pid;
    g_up[cs].cr3 = child_cr3;
    g_up[cs].brk = g_user_brk;
    g_up[cs].mmap_cur = g_mmap_cur;
    for (int i = 0; i < MAX_FDS; i++) { g_up[cs].fds[i] = g_fd[i]; }
    g_up[cs].ret_rax = 0;                        // child sees eax=0 at fork()'s return
    g_up[cs].user_rsp = xk_get_user_rsp();
    g_up[cs].ret_rip = a[6];
    g_up[cs].ret_rflags = a[7];
    for (int ri = 0; ri < 12; ri++) { g_up[cs].regs[ri] = rs[ri]; }
    xk_puts("[fork] pid="); xk_putdec((int)g_linux_pid);
    xk_puts(" fork -> child pid="); xk_putdec((int)child_pid); xk_puts("\r\n");
    return (long)child_pid;                    // the PARENT continues normally
}

// wait4(pid, *status, options, *rusage). Blocks (parks the process) until the waited
// child has exited, then returns its pid with a zero status.
fn long lx_wait4(ulong* a)
{
    ulong want = a[0];
    bool active = false;
    if (want == (ulong)-1 || want == 0)
    {
        for (int i = 0; i < MAX_UPROC; i++) { if (g_up[i].used && g_up[i].pid != g_linux_pid) { active = true; break; } }
    }
    else
    {
        active = proc_pid_active(want);
    }
    if (active)
    {
        if (up_park()) return 0;                   // switched (unreachable)
        return (long)(-EAGAIN);                    // no other runnable process: caller retries
    }
    ulong st = a[1];
    if (st != 0) { for (int i = 0; i < 4; i++) { ((char*)st)[i] = 0; } }
    return (long)want;                             // the reaped pid
}

// Resume the suspended parent after the child has exited. Nothing returned.
fn void lx_resume_parent()
{
    g_fork_pending = false;
    g_linux_pml4 = g_saved_parent_pml4;
    g_user_brk = g_saved_parent_brk;
    g_mmap_cur = g_saved_parent_mmap;
    g_linux_pid = g_saved_parent_pid;
    for (int i = 0; i < MAX_FDS; i++) { g_fd[i] = g_saved_parent_fds[i]; }
    // Select the block with the parent's OWN preserved registers and resume there.
    xk_set_resume_block(&g_parent_resume_regs[0]);
    xk_set_cr3(g_linux_pml4);
    xk_puts("[fork] child exited; resuming parent pid=");
    xk_putdec((int)g_saved_parent_pid); xk_puts("\r\n");
    xk_user_return(g_fork_child_pid, g_saved_parent_rcx, g_saved_parent_user_rsp, g_saved_parent_r11);
}

const ulong ARCH_SET_GS = 0x1001;
const ulong ARCH_SET_FS = 0x1002;
const ulong ARCH_GET_FS = 0x1003;
const ulong ARCH_GET_GS = 0x1004;
const ulong TIOCGWINSZ  = 0x5413;

// ---- additional POSIX syscall helpers ----

// Size (or presence) of a file on the FAT volume; returns true + size for a
// regular file, false if absent. Names match the same prefix logic as open().
fn bool lx_fat_find(char* path, ulong* size_out, bool* is_dir_out)
{
    char* p = path;
    int g = 0;
    while ((char)p[0] == '/' && g < 32) { p++; g++; }
    if (p[0] == 0) { *is_dir_out = true; *size_out = 0; return true; }  // "/" is the root dir
    char[FAT_SECTOR] sec;
    for (uint r = 0; r < FAT_ROOT_SECTORS; r++)
    {
        if (ata_read_sectors(FAT_BASE, FAT_DRIVE, (ulong)FAT_ROOT_START + (ulong)r, 1, &sec[0]) != 0) return false;
        for (int e = 0; e < 16; e++)
        {
            char* en = &sec[e * 32];
            if ((int)((char)en[0]) == 0) return false;
            if ((int)((char)en[0]) == 0xE5) continue;
            if (((int)((char)en[11]) & 0x08) != 0) continue;
            if (fatname_match(&en[0], p))
            {
                *is_dir_out = false;
                *size_out = (ulong)((int)((char)en[28]) & 0xFF) | ((ulong)((int)((char)en[29]) & 0xFF) << 8)
                          | ((ulong)((int)((char)en[30]) & 0xFF) << 16) | ((ulong)((int)((char)en[31]) & 0xFF) << 24);
                return true;
            }
        }
    }
    return false;
}

// Fill the x86-64 kernel 'struct stat' enough for POSIX programs (mode/size/ino...).
fn void lx_stat_fill(char* sb, uint mode, ulong size, bool is_dir)
{
    ulong full = is_dir ? (mode | 0x41EDu) : (mode | 0x81A4u);   // S_IFDIR|0755 or S_IFREG|0644
    ulong a = (ulong)sb;
    for (int i = 0; i < 144; i++) { ((char*)a)[i] = 0; }
    st8(a, 1);              // st_dev
    st8(a + 8, 1);          // st_ino
    st8(a + 16, 1);         // st_nlink
    for (int k = 0; k < 4; k++) { ((char*)a)[24 + k] = (char)((full >> (k * 8)) & 0xFF); }   // st_mode
    st8(a + 48, size);      // st_size
    st8(a + 56, 4096);      // st_blksize
    st8(a + 64, (size + 511) / 512);   // st_blocks
    ulong t = xk_get_ticks() / 100;
    st8(a + 72, t); st8(a + 88, t); st8(a + 104, t);   // atime/mtime/ctime sec
}

fn long lx_stat_path(char* path, char* sb)
{
    char* p = path;
    int g2 = 0;
    while ((char)p[0] == '/' && g2 < 16) { p++; g2++; }
    int vf = vf_classify(p);
    if (vf != VF_UNKNOWN)
    {
        if (vf == VF_NULL || vf == VF_ZERO) { lx_stat_fill(sb, 0, 0, false); return 0; }
        if (vf == VF_DIR) { lx_stat_fill(sb, 0, 0, true); return 0; }
        if (vf == VF_PROC) { lx_stat_fill(sb, 0, 32, false); return 0; }
    }
    ulong size = 0;
    bool isdir = false;
    if (!lx_fat_find(path, &size, &isdir)) return -ENOENT;
    lx_stat_fill(sb, 0, size, isdir);
    return 0;
}

fn long lx_stat_fd(long fd, char* sb)
{
    if (fd < 0 || fd >= MAX_FDS || !g_fd[fd].used) return -EBADF;
    lx_stat_fill(sb, 0, g_fd[fd].len, false);
    return 0;
}

fn long lx_uname(char* buf)
{
    char* sys_  = "xenOS";
    char* node_ = "xen";
    char* rel_  = "0.1.0";
    char* vers_ = "#1 musl-linux-dyn";
    char* mach_ = "x86_64";
    // struct utsname: sysname[65], nodename[65], release[65], version[65], machine[65], domainname[65]
    for (int i = 0; i < 390; i++) { buf[i] = 0; }
    int k = 0; while (sys_[k]) { buf[k] = sys_[k]; k++; }
    k = 0; while (node_[k]) { buf[65 + k] = node_[k]; k++; }
    k = 0; while (rel_[k]) { buf[130 + k] = rel_[k]; k++; }
    k = 0; while (vers_[k]) { buf[195 + k] = vers_[k]; k++; }
    k = 0; while (mach_[k]) { buf[260 + k] = mach_[k]; k++; }
    return 0;
}

// ---- the Linux syscall dispatcher (called by syscall_entry in asm) ----
//   ulong xk_linux_dispatch(ulong nr, ulong* a)  -- a[0..5] = a1..a6 (sysV)
// A negative return is a Linux errno (musl negates it into errno). exit_group
// never returns (it resumes the desktop via umode_resume).

// ---- concurrent-process scheduler helpers (Phase A.1) ----
fn void up_register0()
{
    for (int i = 0; i < MAX_UPROC; i++) { g_up[i].used = false; }
    g_up[0].used = true; g_up[0].runnable = true; g_up[0].parked = false; g_up[0].init = true;
    g_up[0].pid = g_linux_pid;
    g_up[0].cr3 = g_linux_pml4;
    g_up[0].brk = g_user_brk;
    g_up[0].mmap_cur = g_mmap_cur;
    for (int i = 0; i < MAX_FDS; i++) { g_up[0].fds[i] = g_fd[i]; }
    g_up[0].user_rsp = 0; g_up[0].ret_rip = 0; g_up[0].ret_rflags = 0; g_up[0].ret_rax = 0;
    g_cur_up = 0;
}

fn void up_save_current()
{
    int me = g_cur_up;
    g_up[me].cr3 = g_linux_pml4;
    g_up[me].brk = g_user_brk;
    g_up[me].mmap_cur = g_mmap_cur;
    for (int i = 0; i < MAX_FDS; i++) { g_up[me].fds[i] = g_fd[i]; }
}

fn void up_load(int ix)
{
    g_linux_pml4 = g_up[ix].cr3;
    g_user_brk = g_up[ix].brk;
    g_mmap_cur = g_up[ix].mmap_cur;
    for (int i = 0; i < MAX_FDS; i++) { g_fd[i] = g_up[ix].fds[i]; }
    g_linux_pid = g_up[ix].pid;
}

// Switch to process `nxt`. Save the current process's live globals first (it may be
// scheduled again later). If nxt was PARKED, re-dispatch its awaited syscall fresh;
// otherwise enter it at its user return point with ret_rax. NEVER returns.
fn void up_switch_to(int nxt)
{
    if (g_cur_up >= 0 && g_cur_up < MAX_UPROC && g_up[g_cur_up].used) { up_save_current(); }
    g_cur_up = nxt;
    up_load(nxt);
    xk_set_cr3(g_linux_pml4);
    xk_set_resume_block(&g_up[nxt].regs[0]);
    if (g_up[nxt].parked)
    {
        g_up[nxt].parked = false;
        ulong nr = g_up[nxt].sys_nr;
        ulong* a = &g_up[nxt].sys_a[0];
        ulong r = xk_linux_dispatch(nr, a);        // re-run the awaited syscall
        xk_user_return(r, g_up[nxt].ret_rip, g_up[nxt].user_rsp, g_up[nxt].ret_rflags);
    }
    else
    {
        g_up[nxt].init = false;
        xk_user_return(g_up[nxt].ret_rax, g_up[nxt].ret_rip, g_up[nxt].user_rsp, g_up[nxt].ret_rflags);
    }
    // never reached
}

fn int up_next_runnable()
{
    for (int i = 1; i <= MAX_UPROC; i++)
    {
        int k = (g_cur_up + i) % MAX_UPROC;
        if (g_up[k].used && g_up[k].runnable) return k;
    }
    return -1;
}

// Park the current process mid-syscall. If another process is runnable, switch to it
// (never returns -> returns true). Otherwise un-park and return false so the caller
// returns -EAGAIN.
fn bool up_park()
{
    int me = g_cur_up;
    ulong* a = g_disp_a;
    ulong* rs = xk_get_resume_snapshot();
    g_up[me].user_rsp = xk_get_user_rsp();
    g_up[me].ret_rip = a[6];
    g_up[me].ret_rflags = a[7];
    for (int ci = 0; ci < 12; ci++) { g_up[me].regs[ci] = rs[ci]; }
    g_up[me].sys_nr = g_disp_nr;
    for (int ci = 0; ci < 6; ci++) { g_up[me].sys_a[ci] = a[ci]; }
    g_up[me].parked = true;
    g_up[me].runnable = false;
    int nxt = up_next_runnable();
    if (nxt >= 0) { up_switch_to(nxt); return true; }    // never returns
    g_up[me].parked = false;
    g_up[me].runnable = true;
    return false;
}

// Coarse wake: make every parked process runnable again (it re-checks on re-dispatch).
fn void up_wake_all()
{
    for (int i = 0; i < MAX_UPROC; i++)
    {
        if (g_up[i].used && g_up[i].parked) { g_up[i].runnable = true; }
    }
}

fn bool proc_pid_active(ulong pid)
{
    for (int i = 0; i < MAX_UPROC; i++) { if (g_up[i].used && g_up[i].pid == pid) return true; }
    return false;
}

fn ulong xk_linux_dispatch(ulong nr, ulong* a) @export("xk_linux_dispatch")
{
    // record the in-flight syscall (re-dispatch of a parked process reads these)
    g_disp_nr = nr;
    g_disp_a = a;
    if (nr == 60 || nr == 231)                       // exit / exit_group
    {
        xk_puts("\r\n[linux] process exited (code=");
        xk_putdec((int)a[0]);
        xk_puts(") > handing off to the next runnable process\r\n");
                // scheduler: this process is done; wake any parked and hand off
                g_up[g_cur_up].used = false;
                g_up[g_cur_up].runnable = false;
                g_up[g_cur_up].parked = false;
                up_wake_all();
                int nx = up_next_runnable();
                if (nx >= 0) { up_switch_to(nx); return 0; }        // never returns
                g_cur_up = -1;
                umode_resume();                                    // no more processes: desktop
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
    else if (nr == 13 || nr == 14 || nr == 15) { return 0; }  // rt_sigaction/procmask/return stubs
    else if (nr == 4)      { return (ulong)lx_stat_path((char*)(ulong)a[0], (char*)(ulong)a[1]); }   // stat
    else if (nr == 6)      { return (ulong)lx_stat_path((char*)(ulong)a[0], (char*)(ulong)a[1]); }   // lstat
    else if (nr == 5)      { return (ulong)lx_stat_fd((long)a[0], (char*)(ulong)a[1]); }              // fstat
    else if (nr == 262)    { return (ulong)lx_stat_path((char*)(ulong)a[1], (char*)(ulong)a[2]); }    // newfstatat
    else if (nr == 79)     // getcwd
    {
        ((char*)(ulong)a[0])[0] = '/';
        ((char*)(ulong)a[0])[1] = 0;
        return (ulong)a[0];
    }
    else if (nr == 63)     { return (ulong)lx_uname((char*)(ulong)a[0]); }   // uname
    else if (nr == 102 || nr == 107) { return 1000; }                        // getuid/geteuid
    else if (nr == 104 || nr == 108) { return 1000; }                        // getgid/getegid
    else if (nr == 110)    { return 2; }                                     // getppid
    else if (nr == 186)    { return g_linux_pid; }                           // gettid
    else if (nr == 111 || nr == 121) { return g_linux_pid; }                 // getpgrp/getpgid
    else if (nr == 21)     // access
    {
        char* pp = (char*)(ulong)a[0];
        int gp = 0;
        while ((char)pp[0] == '/' && gp < 16) { pp++; gp++; }
        if (vf_classify(pp) != VF_UNKNOWN) return 0;
        ulong s; bool d;
        return (ulong)(lx_fat_find((char*)(ulong)a[0], &s, &d) ? 0 : -ENOENT);
    }
    else if (nr == 89 || nr == 267) { return (ulong)(-ENOENT); }             // readlink/readlinkat
    else if (nr == 35)     { return 0; }                                     // nanosleep
    else if (nr == 202)    { return 0; }                                     // futex
    else if (nr == 62 || nr == 234) { return 0; }                            // kill/tgkill
    else if (nr == 72)     { return 0; }                                     // fcntl
    else if (nr == 24)     { return 0; }                                     // sched_yield
    else if (nr == 97)     // getrlimit
    {
        ulong l = a[1];
        if (l != 0) { st8(l, (ulong)0xFFFFFFFF); st8(l + 8, (ulong)0xFFFFFFFF); }   // rlim_cur/rlim_max
        return 0;
    }
    else if (nr == 302)    // prlimit64
    {
        ulong l = a[2];
        if (l != 0) { st8(l, (ulong)0xFFFFFFFF); st8(l + 8, (ulong)0xFFFFFFFF); }
        return 0;
    }
    else if (nr == 318)    // getrandom
    {
        ulong base = a[1];
        for (ulong i = 0; i < 32 && i < a[2]; i++) { ((char*)(ulong)base)[i] = (char)((int)base + (int)i); }
        return (long)(a[2] < 32 ? a[2] : 32);
    }
    else if (nr == 8)     // lseek
    {
        int fd = (int)a[0];
        if (fd < 0 || fd >= MAX_FDS || !g_fd[fd].used) return (ulong)(-EBADF);
        if (a[2] == 0) { g_fd[fd].pos = a[1]; }
        else if (a[2] == 2) { g_fd[fd].pos = g_fd[fd].len + a[1]; }
        else if (a[2] == 1) { g_fd[fd].pos = g_fd[fd].pos + a[1]; }
        return (ulong)g_fd[fd].pos;
    }
    else if (nr == 32)     // dup
    {
        int src = (int)a[0];
        if (src < 0 || src >= MAX_FDS || !g_fd[src].used) return (ulong)(-EBADF);
        for (int i = 3; i < MAX_FDS; i++) { if (!g_fd[i].used) { g_fd[i] = g_fd[src]; return (ulong)i; } }
        return (ulong)(-EMFILE);
    }
    else if (nr == 57) { return (ulong)lx_fork(a); }                           // fork
    else if (nr == 61) { return (ulong)lx_wait4(a); }                          // wait4
    else if (nr == 53) { return (ulong)lx_sockpair(a); }                       // socketpair (AF_UNIX)
    else if (nr == 41) { return (ulong)lx_socket(a); }                          // socket
    else if (nr == 49) { return (ulong)lx_bind(a); }                            // bind
    else if (nr == 50) { return (ulong)lx_listen(a); }                          // listen
    else if (nr == 42) { return (ulong)lx_connect(a); }                         // connect
    else if (nr == 43) { return (ulong)lx_accept(a); }                          // accept
    else if (nr == 7) { return (ulong)lx_poll(a); }                              // poll
    else if (nr == 271) { return (ulong)lx_poll(a); }                            // ppoll (timeout/sigmask ignored)
    else if (nr == 291) { return (ulong)lx_epoll_create1(a); }                   // epoll_create1
    else if (nr == 233) { return (ulong)lx_epoll_ctl(a); }                       // epoll_ctl
    else if (nr == 232) { return (ulong)lx_epoll_wait(a); }                      // epoll_wait
    else if (nr == 281) { return (ulong)lx_epoll_wait(a); }                      // epoll_pwait
    else if (nr == 56 || nr == 58) { return (ulong)(-ENOSYS); }  // clone/vfork (threads: later)
    else if (nr == 45 || nr == 44 || nr == 46 || nr == 54) { return (ulong)(-ENOSYS); } // sockets (sendmsg/recvmsg/etc)
    // Unknown syscall: print which one, then ENOSYS (keeps musl's failure visible).
    xk_puts("[linux] unimplemented syscall nr=");
    xk_putdec((int)nr);
    xk_puts("\\r\\n");
    return (ulong)(-ENOSYS);
}

// ---- mark every 2 MiB page a PT_LOAD segment spans as user-accessible ----
fn void mark_seg_users(ulong va, ulong memsz)
{
    ulong p0 = va & ~(ulong)0x1FFFFF;
    ulong p1 = (va + memsz) & ~(ulong)0x1FFFFF;
    for (ulong pg = p0; pg <= p1; pg += (ulong)0x200000) { mark_user_pde(g_linux_pml4, pg); }
}

// Map an ELF64 binary into the (already created) process address space.
// `base` is the load base: base==0 for ET_EXEC (absolute vaddrs), a chosen
// base for ET_DYN (segments placed at base+vaddr). Copies file bytes, zeroes
// BSS, marks spanned pages U/S. Returns absolute entry/phdr and phnum.
fn bool linux_map_elf(char* bin, uint len, ulong base, ulong* entry_out, ulong* phdr_out, uint* phnum_out)
{
    if (len < 64) { xk_puts("[linux] blob too small\r\n"); return false; }
    if ((char)bin[0] != (char)0x7F || (char)bin[1] != 'E' || (char)bin[2] != 'L' || (char)bin[3] != 'F')
    { xk_puts("[linux] bad ELF magic\r\n"); return false; }
    if ((char)bin[4] != (char)2 || (char)bin[5] != (char)1)
    { xk_puts("[linux] not ELF64 LE\r\n"); return false; }
    uint etype = rd_u16(bin, ELF_E_TYPE);
    uint emach = rd_u16(bin, ELF_E_MACH);
    if (etype != 2 && etype != 3) { xk_puts("[linux] not an ELF object\r\n"); return false; }
    if (emach != EM_X86_64) { xk_puts("[linux] not x86-64\r\n"); return false; }
    ulong entry_off = rd_u64(bin, ELF_E_ENTRY);
    ulong phoff = rd_u64(bin, ELF_E_PHOFF);
    uint phent = rd_u16(bin, ELF_E_PHENTSZ);
    uint phnum = rd_u16(bin, ELF_E_PHNUM);
    if (phent != PH_SIZE) { xk_puts("[linux] unexpected phdr size\r\n"); return false; }
    ulong elf_base = base;    // loaded address of file offset 0 (the ELF header)
    for (uint i = 0; i < phnum; i++)
    {
        ulong ph = phoff + (ulong)i * PH_SIZE;
        if (rd_u32(bin, (uint)ph) != PT_LOAD) continue;
        ulong poff  = rd_u64(bin, (uint)(ph + 8));
        ulong vaddr = rd_u64(bin, (uint)(ph + PH_OFF_VADDR));
        ulong filesz = rd_u64(bin, (uint)(ph + PH_OFF_FILESZ));
        ulong memsz  = rd_u64(bin, (uint)(ph + PH_OFF_MEMSZ));
        ulong va = base + vaddr;
        if (poff == 0) { elf_base = va; }      // the segment that holds the ELF header
        mark_seg_users(va, memsz);
        xk_puts("[linux]  load ");
        xk_puthex(va);
        xk_puts(" +");
        xk_putdec((int)memsz);
        xk_puts("\r\n");
        for (ulong k = 0; k < filesz; k++) { ((char*)va)[k] = bin[poff + k]; }
        if (memsz > filesz) { kmemzero((void*)(ulong)(va + filesz), memsz - filesz); }
    }
    *entry_out = base + entry_off;
    *phdr_out = elf_base + phoff;    // where the program-header table really lives in memory
    *phnum_out = phnum;
    return true;
}

// Build the Linux SysV initial stack (argc/argv/envp/auxv) for a process whose
// binary program-header table is at `phdr`, entry at `entry`, load base at
// `base` (0 = static, else the interpreter's base -> AT_BASE). The block is
// laid out CONTIGUOUSLY upward from a 16-byte-aligned rsp (no gaps), so the
// interpreter/auxv scanning sees exactly argc..argv..envp..auxv.
fn bool linux_build_stack(ulong phdr, ulong entry, ulong base, uint phnum, ulong* sp_out)
{
    ulong[40] aux;
    int an = 0;
    aux[an++] = 3;   aux[an++] = phdr;           // AT_PHDR
    aux[an++] = 4;   aux[an++] = 56;             // AT_PHENT
    aux[an++] = 5;   aux[an++] = (ulong)phnum;   // AT_PHNUM
    aux[an++] = 6;   aux[an++] = 4096;           // AT_PAGESZ
    aux[an++] = 7;   aux[an++] = base;           // AT_BASE (interp base, 0=static)
    aux[an++] = 9;   aux[an++] = entry;          // AT_ENTRY (main's entry)
    aux[an++] = 25;  aux[an++] = 0;              // AT_RANDOM filled below
    aux[an++] = 11;  aux[an++] = g_linux_pid;    // AT_UID
    aux[an++] = 12;  aux[an++] = g_linux_pid;    // AT_EUID
    aux[an++] = 13;  aux[an++] = g_linux_pid;    // AT_GID
    aux[an++] = 14;  aux[an++] = g_linux_pid;    // AT_EGID
    aux[an++] = 0;   aux[an++] = 0;              // terminator

    const char* PROG = "/UHELLO.EXE";
    int plen = 0;
    while (PROG[plen] != 0) plen++;
    ulong extra = (ulong)an * 8 + 32;            // auxv + argc+argv0+argv1+envp0
    ulong strsz = (ulong)plen + 1 + 16;          // path string + AT_RANDOM bytes
    ulong rsp = (LX_STACK_TOP - (extra + strsz)) & ~((ulong)15);

    ulong random_ptr = rsp + extra;              // AT_RANDOM occupies the 16 bytes
    ulong path_str   = random_ptr + 16;          // then the path string at the top

    // find aux slot for '25' (AT_RANDOM) and write the real pointer
    for (int j = 0; j + 1 < an; j += 2) { if (aux[j] == 25) aux[j + 1] = random_ptr; }

    st8(rsp, 1);                 // argc
    st8(rsp + 8, path_str);      // argv[0]
    st8(rsp + 16, 0);            // argv[1] = NULL
    st8(rsp + 24, 0);            // envp[0] = NULL
    for (int i = 0; i < an; i++) { st8(rsp + 32 + (ulong)i * 8, aux[i]); }   // auxv
    for (int i = 0; i < 16; i++) { ((char*)random_ptr)[i] = (char)((int)random_ptr + i); }
    for (int i = 0; i < plen; i++) { ((char*)path_str)[i] = PROG[i]; }
    ((char*)path_str)[plen] = 0;

    *sp_out = rsp;
    return true;
}

fn void linux_launch(ulong entry, ulong stack)
{
    xk_puts("[linux] launching musl ELF (entry=");
    xk_puthex(entry);
    xk_puts(" sp=");
    xk_puthex(stack);
    xk_puts(")\r\n");
    linux_fd_init();
    up_register0();          // proc 0 = this first process, enters the scheduler
    xk_mask_hw_irqs(1);      // keep device IRQs off while the ring-3 process runs
    xk_set_cr3(g_linux_pml4);
    xk_enter_ring3(entry, stack);
}

// Dynamically-linked launcher: map the dynamic main + the ld-musl interpreter
// (its libc, which IS the dynamic linker) loaded from the FAT volume, build
// the auxv (AT_BASE=interpreter base, AT_PHDR/AT_ENTRY=main) and enter the
// interpreter. musl's _dlstart does all relocations/symbol resolution.
fn bool linux_exec_dynamic()
{
    // dynamic main (embedded dyn_blob, ET_EXEC at 0x400000)
    ulong m_entry = 0;
    ulong m_phdr = 0;
    uint m_phnum = 0;
    if (!linux_map_elf(&dyn_blob[0], DYN_BLOB_LEN, 0, &m_entry, &m_phdr, &m_phnum))
    {
        xk_puts("[linux] dynamic: no main\r\n");
        return false;
    }
    // read the interpreter (musl's ldso == libc.so) from the FAT data volume
    uint cap = 900000;
    char* ibuf = (char*)kmalloc(cap);
    if (ibuf == null) { xk_puts("[linux] dynamic: no heap for interp\r\n"); return false; }
    uint ilen = 0;
    int r = fat_read_file("LIBC.SO", ibuf, cap, &ilen);
    if (r != 0) { xk_puts("[linux] dynamic: interpreter not on disk\r\n"); kfree(ibuf); return false; }
    ulong i_entry = 0;
    ulong i_phdr = 0;
    uint i_phnum = 0;
    bool ok = linux_map_elf(ibuf, ilen, LX_INTERP_BASE, &i_entry, &i_phdr, &i_phnum);
    kfree(ibuf);
    if (!ok) { xk_puts("[linux] dynamic: interp map failed\r\n"); return false; }
    ulong stack = 0;
    if (!linux_build_stack(m_phdr, m_entry, LX_INTERP_BASE, m_phnum, &stack))
    {
        xk_puts("[linux] dynamic: no stack\r\n");
        return false;
    }
    xk_puts("[linux] dynamic: main@");
    xk_puthex(m_entry);
    xk_puts(" interp@");
    xk_puthex(i_entry);
    xk_puts(" (base ");
    xk_puthex(LX_INTERP_BASE);
    xk_puts(")\r\n");
    linux_launch(i_entry, stack);
    return true;
}

// ---- boot entry: load + launch the embedded / on-disk musl ELF ----
fn void linux_boot_exec()
{
    linux_blob_init();     // fills the BSS static blob from generated byte code
    dyn_blob_init();       // fills the BSS dynamic-main blob
    xk_puts("[linux] enabling SYSCALL MSRs\r\n");
    xk_linux_syscall_init();

    g_linux_pml4 = create_process_addrspace(LX_USER_START);
    if (g_linux_pml4 == 0) { xk_puts("[linux] no frames for address space\r\n"); umode_enter(); return; }
    // mark user code+heap region and the stack region U/S
    for (ulong v = LX_USER_START; v < LX_HEAP_END; v += (ulong)0x200000) { mark_user_pde(g_linux_pml4, v); }
    for (ulong v = (ulong)0x0FC00000; v < LX_STACK_TOP; v += (ulong)0x200000) { mark_user_pde(g_linux_pml4, v); }

    // Prefer the dynamically-linked binary (loader + ld-musl interp); fall back
    // to the static one if the interpreter cannot be sourced.
    if (linux_exec_dynamic())
    {
        return;
    }
    // static fallback (the committed static musl blob)
    ulong entry = 0;
    ulong phdr = 0;
    ulong stack = 0;
    uint phnum = 0;
    uint m_phnum = 0;
    ulong m_phdr = LX_USER_START;
    if (linux_map_elf(&linux_blob[0], LINUX_BLOB_LEN, 0, &entry, &m_phdr, &m_phnum))
    {
        if (linux_build_stack(m_phdr, entry, 0, m_phnum, &stack))
        {
            linux_launch(entry, stack);
            return;
        }
    }
    xk_puts("[linux] load failed; falling back to the native ring-3 demo\r\n");
    umode_enter();
}