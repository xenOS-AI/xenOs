module xk;

// ============================================================================
// System-call interface via INT 0x80 (vector 128). Even though userland runs
// at ring 0 today, this is the syscall ABI that future ring-3 processes use.
// Registers: rax=n, rbx=arg1, rcx=arg2, rdx=arg3; result in rax.
// The asm gate (isr_stub_128) + xk_syscall() are in asm_runtime.asm.
// ============================================================================

const uint SYS_PUTS    = 1;   // arg1 = char* text, arg2 = destination (0 = serial)
const uint SYS_GETPID  = 2;
const uint SYS_TICKS   = 3;
const uint SYS_UMSG    = 10;  // ring-3: print a banner (no user pointers)
const uint SYS_EXIT    = 12;  // ring-3: return to ring 0 (resume the desktop)

extern fn ulong xk_syscall(ulong n, ulong a, ulong b, ulong c);
extern fn void xk_iret_ring0(ulong target);

// dispatch a syscall coming through the IDT gate (IntFrame holds the regs)
fn ulong sys_dispatch(IntFrame* f)
{
    ulong n = f.rax;
    if (n == SYS_PUTS)   { xk_puts((char*)f.rbx); return 0; }
    else if (n == SYS_GETPID) { return (ulong)g_tasks[g_current].pid; }
    else if (n == SYS_TICKS)  { return g_ticks; }
    else if (n == SYS_UMSG)   { xk_puts("[user] hello from ring 3 (syscall)\r\n"); return 0; }
    else if (n == SYS_EXIT)
    {
        // Hand control back to ring-0 by simply CALLING the resume path from
        // within the (ring-0) syscall handler; it runs the desktop idle loop
        // and never returns here. (iretq-ing back to ring-0 from a ring-3-
        // origin ISR frame is fragile, so we avoid it.)
        xk_puts("[user] SYS_EXIT -> returning to ring 0\r\n");
        umode_resume();
        return 0;                       // unreached
    }
    // Unknown number: reject. A ring-3 caller must not be able to ask for
    // anything we did not implement.
    if (((uint)f.cs & 3) == 3)
    {
        xk_puts("[protect] ring-3 attempted unknown syscall; rejected\r\n");
        return 0;
    }
    return (ulong)-1;
}

// convenience wrappers for kernel code / the demonstration shell builtin
fn ulong sys_puts(char* s)       { return xk_syscall(SYS_PUTS, (ulong)s, 0, 0); }
fn int  sys_getpid()             { return (int)xk_syscall(SYS_GETPID, 0, 0, 0); }
fn ulong sys_ticks()             { return xk_syscall(SYS_TICKS, 0, 0, 0); }