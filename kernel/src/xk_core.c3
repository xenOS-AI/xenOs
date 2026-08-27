module xk;

// ---- low-level asm runtime (asm_runtime.asm) ----
extern fn void xk_outb(uint port, char val);
extern fn char xk_inb(uint port);
extern fn void xk_io_wait();
extern fn void xk_cli();
extern fn void xk_sti();
extern fn void xk_hlt();
extern fn void xk_pause();
extern fn void xk_lgdt(ulong base, ushort limit);
extern fn void xk_lidt(ulong base, ushort limit);
extern fn void xk_ltr(ushort selector);
extern fn ulong xk_read_cr2();
extern fn ulong xk_read_cr3();
extern fn ulong xk_rdtsc();

// ---- BootInfo passed by the bootloader at physical 0x7000 ----
struct BootInfo
{
    ulong fb_addr;
    uint  width;
    uint  height;
    uint  pitch;
    uint  bpp;
    uint  mem_mb;
    uint  drive;
}

const ulong BOOTINFO_ADDR = 0x7000;

fn BootInfo* get_bootinfo()
{
    return (BootInfo*)BOOTINFO_ADDR;
}

// ---- minimal homegrown memory helpers (no libc) ----
fn void* kmemcpy(void* dst, void* src, ulong n)
{
    // bytewise copy
    for (ulong i = 0; i < n; i++)
    {
        ((char*)dst)[i] = ((char*)src)[i];
    }
    return dst;
}

fn void* kmemset(void* dst, int c, ulong n)
{
    char b = (char)c;
    for (ulong i = 0; i < n; i++)
    {
        ((char*)dst)[i] = b;
    }
    return dst;
}

fn void* kmemzero(void* dst, ulong n)
{
    for (ulong i = 0; i < n; i++)
    {
        ((char*)dst)[i] = 0;
    }
    return dst;
}

// ---- kernel boot logic (invoked from the asm entry in xk_main.c3) ----
fn void xk_fill_fb(uint color)
{
    BootInfo* bi = get_bootinfo();
    if (bi.bpp != 32) { xk_puts("[fb] not 32bpp (bpp=");
        xk_putdec((int)bi.bpp); xk_puts(")\r\n"); return; }
    uint* px = (uint*)bi.fb_addr;
    px[0] = color; px[1] = color;
    xk_puts("[fb] wrote 2px; readback=");
    xk_puthex_32(px[0]);
    xk_puts("\r\n");
    ulong count = (ulong)bi.width * (ulong)bi.height;
    ulong marker = 0;
    for (ulong i = 0; i < count; i++)
    {
        px[i] = color;
        if ((i & 0xFFFF) == 0xFFFF) { xk_puts("."); marker++; }
    }
    xk_puts("\r\n[fb] filled all pixels (64K-batches=");
    xk_putdec((int)marker);
    xk_puts(")\r\n");
}

fn void xk_boot()
{
    xk_serial_init();
    xk_puts("\r\n=== xenOS kernel 0.1 - hand-written in C3 ===\r\n");

    BootInfo* bi = get_bootinfo();
    xk_puts("[boot] framebuffer addr = ");
    xk_puthex(bi.fb_addr);
    xk_puts("\r\n");
    xk_puts("[boot] resolution       = ");
    xk_putdec((int)bi.width);
    xk_putc('x');
    xk_putdec((int)bi.height);
    xk_puts(" pitch=");
    xk_putdec((int)bi.pitch);
    xk_puts(" bpp=");
    xk_putdec((int)bi.bpp);
    xk_puts("\r\n");
    xk_puts("[boot] memory           = ");
    xk_putdec((int)bi.mem_mb);
    xk_puts(" MiB\r\n");

    if (bi.bpp == 32)
    {
        xk_puts("[display] framebuffer initialised (800x600x32)\r\n");
        font_init();
        xk_puts("[fb] 8x8 font ready\r\n");
    }
    else
    {
        xk_puts("[display] no usable framebuffer; serial console only\r\n");
    }

    frame_init();
    xk_puts("[mem] frame allocator: ");
    xk_putdec((int)g_total_frames);
    xk_puts(" frames, ");
    xk_putdec((int)g_used_frames);
    xk_puts(" used\r\n");

    xk_intr_init();
    xk_kbd_init();
    xk_mouse_init();
    wm_init();
    wm_register_apps();

    thread_init();
    thread_spawn_demos();

    xk_puts("[kernel] init ok. graphical desktop ready\r\n");
    while (true)
    {
        thread_yield();         // cooperative multitasking with task slots 1+
        xk_hlt();

        // keyboard -> focused window
        while (kbd_has())
        {
            wm_key(kbd_pop());
        }
        // window-manager input (mouse) + repaint
        wm_tick();

        // periodic app updates
        if ((g_ticks % 100) == 0) app_clock_update();
        if ((g_ticks % 12) == 0) app_demo_update();
        if ((g_ticks % 2) == 0)
        {
            fb_cursor(mouse_x, mouse_y);
            fb_blit_rect(mouse_x - 8, mouse_y - 8, 20, 20);
        }
    }
}

// ---- serial (COM1) ----
const ushort COM1 = 0x3F8;

fn void xk_serial_init()
{
    xk_outb(COM1 + 1, 0);        // disable interrupts
    xk_outb(COM1 + 3, (char)0x80); // enable DLAB
    xk_outb(COM1 + 0, (char)0x03); // divisor low  -> 38400 baud
    xk_outb(COM1 + 1, (char)0x00); // divisor high
    xk_outb(COM1 + 3, (char)0x03); // 8N1
    xk_outb(COM1 + 2, (char)0xC7); // FIFO enable/clear
    xk_outb(COM1 + 4, (char)0x0B); // IRQs on, OUT2 on
}

fn void xk_serial_putc(char c)
{
    // wait for transmitter empty
    int timeout = 0;
    while (((int)xk_inb(COM1 + 5) & 0x20) == 0)
    {
        timeout++;
        if (timeout > 100000) break;
    }
    xk_outb(COM1, c);
    if (c == '\n') xk_serial_putc('\r');
}

fn void xk_serial_puts(char* s)
{
    while (*s != 0)
    {
        xk_serial_putc(*s);
        s++;
    }
}

fn void xk_putc(char c)
{
    xk_serial_putc(c);
}

fn void xk_puts(char* s)
{
    xk_serial_puts(s);
}

fn void xk_puthex_32(uint v)
{
    for (int i = 7; i >= 0; i--)
    {
        int nib = (int)((v >> (uint)(i * 4)) & 0xF);
        xk_serial_putc(nib < 10 ? (char)('0' + nib) : (char)('A' + (nib - 10)));
    }
}

fn void xk_puthex(ulong v)
{
    xk_puts("0x");
    xk_puthex_32((uint)(v >> 32));
    xk_puthex_32((uint)v);
}

fn void xk_putdec(int v)
{
    if (v < 0)
    {
        xk_serial_putc('-');
        v = -v;
    }
    char[12] buf;
    int idx = 0;
    if (v == 0) { xk_serial_putc('0'); return; }
    while (v > 0)
    {
        buf[idx] = (char)('0' + (v % 10));
        idx++;
        v /= 10;
    }
    for (int i = idx - 1; i >= 0; i--)
    {
        xk_serial_putc(buf[i]);
    }
}