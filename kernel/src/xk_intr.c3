module xk;

// ---- long-mode IDT entry (16 bytes) ----
struct IdtEntry
{
    ushort off_lo;    // 0
    ushort selector;  // 2
    ushort ist_type;  // 4  (IST in low 3 bits, type/attrs in high byte)
    ushort off_mid;   // 6
    uint   off_hi;    // 8
    uint   rsrv;      // 12
}

// ---- Interrupt frame as pushed by isr_common (asm_runtime.asm) ----
// isr_common pushes GPRs rax..r15 in that order, so the LAST push (r15) sits
// at the lowest address (offset 0); the GPR fields below are therefore in
// reverse order. vector/error_code/rip/cs/rflags follow from the stub+CPU.
struct IntFrame
{
    ulong r15, r14, r13, r12, r11, r10, r9, r8;
    ulong rbp, rdi, rsi, rdx, rcx, rbx, rax;
    ulong vector;
    ulong error_code;
    ulong rip, cs, rflags;
}

// ---- external from asm_runtime.asm ----
extern fn ulong* xk_get_stub_table();
// xk_lidt / xk_lgdt / xk_ltr / xk_sti / xk_cli / xk_hlt declared in xk_core.c3

const int IDT_STUBS = 48;       // vectors 0..47 have stubs
const int IDT_TOTAL = 129;      // index space up to INT 0x80 (128)
IdtEntry[IDT_TOTAL] g_idt;      // BSS (zeroed at kernel entry)
const ushort KERNEL_CODE64 = 0x18;  // code64 selector from the boot GDT

// IRQ dispatch table (16 entries).
alias IrqHandler = fn void(IntFrame*);
IrqHandler[16] irq_table;      // array of function-pointer values (BSS-zeroed = null)
ulong g_ticks;

fn void idt_set(void* base, int index, ulong handler, ushort selector, uint type_attr)
{
    IdtEntry* e = (IdtEntry*)base + index;
    e.off_lo = (ushort)(handler & 0xFFFF);
    e.selector = selector;
    e.ist_type = (ushort)(((type_attr << 8) & 0xFF00) | 0x0000);
    e.off_mid = (ushort)((handler >> 16) & 0xFFFF);
    e.off_hi = (uint)(handler >> 32);
    e.rsrv = 0;
}

fn void xk_pic_init()
{
    // Remap 8259 PIC: primary IRQ0..7 -> vectors 0x20..0x27, slave -> 0x28..0x2F
    xk_outb(0x20, (char)0x11); xk_outb(0xA0, (char)0x11);   // ICW1: init
    xk_outb(0x21, (char)0x20); xk_outb(0xA1, (char)0x28);   // ICW2: base vectors
    xk_outb(0x21, (char)0x04); xk_outb(0xA1, (char)0x02);   // ICW3: slave on IRQ2
    xk_outb(0x21, (char)0x01); xk_outb(0xA1, (char)0x01);   // ICW4: 8086 mode
    // Master: unmask IRQ0 (timer), IRQ1 (keyboard), IRQ2 (cascade).
    // Slave:  unmask IRQ12 (mouse).
    xk_outb(0x21, (char)0xF8);
    xk_outb(0xA1, (char)0xEF);
}

fn void xk_pit_init(int hz)
{
    int divisor = 1193182 / hz;
    xk_outb(0x43, (char)0x36);                 // channel 0, lo/hi, rate generator
    xk_outb(0x40, (char)(divisor & 0xFF));
    xk_outb(0x40, (char)((divisor >> 8) & 0xFF));
}

fn void xk_eoi(uint irq)
{
    if (irq >= 8) xk_outb(0xA0, (char)0x20);   // slave
    xk_outb(0x20, (char)0x20);                 // master
}

// ---- timer (IRQ0) ----
fn void irq_timer(IntFrame* f)
{
    g_ticks++;
}

// ---- default / unhandled IRQ ----
fn void irq_other(IntFrame* f)
{
    xk_puts("[irq] unhandled, vector=");
    xk_putdec((int)f.vector);
    xk_puts("\r\n");
}

fn void xk_fault(uint v, IntFrame* f)
{
    xk_puts("\r\n*** EXCEPTION vector=");
    xk_putdec((int)v);
    xk_puts(" err=");
    xk_puthex(f.error_code);
    xk_puts(" rip=");
    xk_puthex(f.rip);
    xk_puts(" cr2=");
    xk_puthex(xk_read_cr2());
    xk_puts("\r\n*** kernel halted\r\n");
    xk_cli();
    while (true) xk_hlt();
}

fn void xk_handle_isr(IntFrame* f) @export("xk_handle_isr")
{
    uint v = (uint)f.vector;
    if (v == 128)
    {
        // system call (INT 0x80): result returned in the frame's rax
        f.rax = sys_dispatch(f);
        return;
    }
    if (v < 32)
    {
        xk_fault(v, f);
        return;
    }
    uint irq = v - 32;
    IrqHandler h = irq_table[irq];
    if (h != null)
    {
        h(f);
    }
    else
    {
        irq_other(f);
    }
    xk_eoi(irq);
}

fn void xk_intr_init()
{
    // Build the IDT from the assembly stub table (selector = code64).
    ulong* stubs = xk_get_stub_table();
    for (int i = 0; i < IDT_STUBS; i++)
    {
        idt_set(&g_idt, i, stubs[i], KERNEL_CODE64, 0x8E);
    }
    // vector 128 = INT 0x80 (system-call gate) lives at stub_table[48]
    idt_set(&g_idt, 128, stubs[IDT_STUBS], KERNEL_CODE64, 0x8E);
    xk_lidt((ulong)&g_idt, (ushort)(IDT_TOTAL * 16 - 1));

    xk_pic_init();
    xk_pit_init(100);
    irq_table[0] = &irq_timer;
    xk_puts("[intr] IDT+PIC+PIT ready\r\n");
    xk_sti();
}