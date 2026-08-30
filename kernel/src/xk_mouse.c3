module xk;

// ---- PS/2 mouse driver (IRQ12, 3-byte standard packets) ----

int mouse_x;
int mouse_y;
uint mouse_buttons;   // bit0 left, bit1 right, bit2 middle
int g_mouse_irq;      // debug: how many mouse IRQs we've serviced

fn void irq_mouse(IntFrame* f)
{
    g_mouse_irq++;
    while (((int)xk_inb(0x64) & 0x01) != 0)
    {
        char b = xk_inb(0x60);
        mouse_packet((uint)b);
    }
}

// packet assembly state machine
char[3] mouse_pkt;
int  mouse_pkt_idx;

fn void mouse_packet(uint b)
{
    if (mouse_pkt_idx == 0)
    {
        // first byte: bit3 must be set (packet start marker)
        if ((b & 0x08) == 0)
        {
            // drop stray bytes; wait for a proper start byte
            return;
        }
        mouse_pkt[0] = (char)b;
        mouse_pkt_idx = 1;
        return;
    }
    mouse_pkt[mouse_pkt_idx] = (char)b;
    mouse_pkt_idx++;
    if (mouse_pkt_idx == 3)
    {
        mouse_pkt_idx = 0;
        apply_mouse_packet();
    }
}

fn void apply_mouse_packet()
{
    uint b0 = (uint)mouse_pkt[0];
    mouse_buttons = (b0 & 0x07);           // left/right/middle

    // relative movement (sign-extend the 8-bit values)
    int dx = (int)(char)mouse_pkt[1];
    int dy = (int)(char)mouse_pkt[2];

    // Y positive is down on screen (mouse away from user = +dy)
    mouse_x = mouse_x + dx;
    mouse_y = mouse_y + dy;
    if (mouse_x < 0) mouse_x = 0;
    if (mouse_x > g_fb_w - 1) mouse_x = g_fb_w - 1;
    if (mouse_y < 0) mouse_y = 0;
    if (mouse_y > g_fb_h - 1) mouse_y = g_fb_h - 1;
}

fn void xk_mouse_init()
{
    mouse_pkt_idx = 0;

    // ---- configure the 8042 controller: enable the second (aux) port IRQ
    // bit1 so the controller asserts IRQ12 when the mouse sends data. ----
    xk_outb(0x64, (char)0x20);                    // read controller config byte
    xk_io_wait();
    char cfg = xk_inb(0x60);
    int c = ((int)cfg | 0x03) & ~0x30;            // IRQ1+IRQ12 enabled, clocks on
    xk_outb(0x64, (char)0x60);                    // write config
    xk_io_wait();
    xk_outb(0x60, (char)c);
    xk_io_wait();

    xk_outb(0x64, (char)0xA8);                    // enable aux device
    xk_io_wait();

    // mouse defaults, then enable streaming
    xk_outb(0x64, (char)0xD4); xk_io_wait();
    xk_outb(0x60, (char)0xF6); xk_io_wait();
    xk_outb(0x64, (char)0xD4); xk_io_wait();
    xk_outb(0x60, (char)0xF4); xk_io_wait();

    // drain any ACK / pending bytes so packet alignment starts clean
    for (int i = 0; i < 8; i++)
    {
        if (((int)xk_inb(0x64) & 0x01) != 0)
        {
            xk_inb(0x60);
        }
    }
    mouse_pkt_idx = 0;

    irq_table[12] = &irq_mouse;
    mouse_x = g_fb_w / 2;
    mouse_y = g_fb_h / 2;
    cur_prev_x = -1;   // no cursor drawn yet (used by the VRAM cursor overlay)
    g_mouse_irq = 0;
    xk_puts("[mouse] PS/2 mouse init done\r\n");
}