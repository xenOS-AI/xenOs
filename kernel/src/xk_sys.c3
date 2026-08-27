module xk;

// ============================================================================
// System-call interface via INT 0x80 (vector 128). Even though userland runs
// at ring 0 today, this is the syscall ABI that future ring-3 processes use.
// Registers: rax=n, rbx=arg1, rcx=arg2, rdx=arg3; result in rax.
// The asm gate (isr_stub_128) + xk_syscall() are in asm_runtime.asm.
// ============================================================================

const uint SYS_PUTS   = 1;   // arg1 = char* text, arg2 = destination (0 = serial)
const uint SYS_GETPID = 2;
const uint SYS_TICKS  = 3;

extern fn ulong xk_syscall(ulong n, ulong a, ulong b, ulong c);

// dispatch a syscall coming through the IDT gate (IntFrame holds the regs)
fn ulong sys_dispatch(IntFrame* f)
{
    ulong n = f.rax;
    if (n == SYS_PUTS)   { xk_puts((char*)f.rbx); return 0; }
    else if (n == SYS_GETPID) { return (ulong)g_tasks[g_current].pid; }
    else if (n == SYS_TICKS)  { return g_ticks; }
    return (ulong)-1;
}

// convenience wrappers for kernel code / the demonstration shell builtin
fn ulong sys_puts(char* s)       { return xk_syscall(SYS_PUTS, (ulong)s, 0, 0); }
fn int  sys_getpid()             { return (int)xk_syscall(SYS_GETPID, 0, 0, 0); }
fn ulong sys_ticks()             { return xk_syscall(SYS_TICKS, 0, 0, 0); }