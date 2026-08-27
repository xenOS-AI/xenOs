module xk;

// ---- PS/2 keyboard driver (scancode set 1), IRQ1 ----
// (xk_inb / xk_outb are declared in xk_core.c3)

const int KBD_BUF_SIZE = 512;
char[KBD_BUF_SIZE] kbd_buf;
uint kbd_head;
uint kbd_tail;
bool shift_held;

fn bool kbd_has()
{
    return kbd_head != kbd_tail;
}

fn char kbd_pop()
{
    if (kbd_head == kbd_tail) return 0;
    char c = kbd_buf[(kbd_tail & (KBD_BUF_SIZE - 1))];
    kbd_tail++;
    return c;
}

// Map base scancode -> ASCII (no shift). 0 = ignore.
char[128] kbd_map;

fn void kbd_init_map()
{
    for (int i = 0; i < 128; i++) kbd_map[i] = 0;
    kbd_map[0x01] = 0x1B;            // Esc
    kbd_map[0x0E] = 0x08;            // Backspace
    kbd_map[0x0F] = '\t';
    kbd_map[0x1C] = '\n';            // Enter
    kbd_map[0x39] = ' ';
    kbd_map[0x0B] = '0'; kbd_map[0x02] = '1'; kbd_map[0x03] = '2';
    kbd_map[0x04] = '3'; kbd_map[0x05] = '4'; kbd_map[0x06] = '5';
    kbd_map[0x07] = '6'; kbd_map[0x08] = '7'; kbd_map[0x09] = '8';
    kbd_map[0x0A] = '9';
    kbd_map[0x0C] = '-'; kbd_map[0x0D] = '='; kbd_map[0x0E] = 0x08;
    // top row letters
    kbd_map[0x10] = 'q'; kbd_map[0x11] = 'w'; kbd_map[0x12] = 'e';
    kbd_map[0x13] = 'r'; kbd_map[0x14] = 't'; kbd_map[0x15] = 'y';
    kbd_map[0x16] = 'u'; kbd_map[0x17] = 'i'; kbd_map[0x18] = 'o';
    kbd_map[0x19] = 'p';
    kbd_map[0x1A] = '['; kbd_map[0x1B] = ']';
    // home row
    kbd_map[0x1E] = 'a'; kbd_map[0x1F] = 's'; kbd_map[0x20] = 'd';
    kbd_map[0x21] = 'f'; kbd_map[0x22] = 'g'; kbd_map[0x23] = 'h';
    kbd_map[0x24] = 'j'; kbd_map[0x25] = 'k'; kbd_map[0x26] = 'l';
    kbd_map[0x27] = ';'; kbd_map[0x28] = '\''; kbd_map[0x2B] = '\\';
    // bottom row
    kbd_map[0x2C] = 'z'; kbd_map[0x2D] = 'x'; kbd_map[0x2E] = 'c';
    kbd_map[0x2F] = 'v'; kbd_map[0x30] = 'b'; kbd_map[0x31] = 'n';
    kbd_map[0x32] = 'm'; kbd_map[0x33] = ','; kbd_map[0x34] = '.';
    kbd_map[0x35] = '/';
}

// Shifted variants for the punctuation/digits that change.
fn char kbd_shift_char(char c)
{
    if (c >= 'a' && c <= 'z') return (char)(c - 'a' + 'A');
    switch (c)
    {
        case '1': return '!';
        case '2': return '@';
        case '3': return '#';
        case '4': return '$';
        case '5': return '%';
        case '6': return '^';
        case '7': return '&';
        case '8': return '*';
        case '9': return '(';
        case '0': return ')';
        case '-': return '_';
        case '=': return '+';
        case '[': return '{';
        case ']': return '}';
        case ';': return ':';
        case '\'': return '"';
        case ',': return '<';
        case '.': return '>';
        case '/': return '?';
        case '\\': return '|';
        case '`': return '~';
        default: return c;
    }
}

fn void kbd_put(char c)
{
    kbd_buf[(kbd_head & (KBD_BUF_SIZE - 1))] = c;
    kbd_head++;
}

fn void irq_kbd(IntFrame* f)
{
    // drain all pending scancodes from the controller
    while (((int)xk_inb(0x64) & 0x01) != 0)
    {
        char sc = xk_inb(0x60);
        handle_scancode((uint)sc);
    }
}

fn void handle_scancode(uint sc)
{
    if (sc == 0xE0)
    {
        // extended key prefix: consume the following scancode and ignore it for now
        kbd_ext_pending = true;
        return;
    }
    if (kbd_ext_pending)
    {
        kbd_ext_pending = false;
        return; // arrows/edits not mapped yet
    }
    if ((sc & 0x80) != 0)
    {
        // break code (release)
        uint make = sc & 0x7F;
        if (make == 0x2A || make == 0x36) shift_held = false;
        return;
    }
    // make code
    if (sc == 0x2A || sc == 0x36) { shift_held = true; return; }
    if (sc == 0x1D || sc == 0x38) return; // ctrl / alt: ignore
    char c = kbd_map[sc & 0x7F];
    if (c == 0) return;
    if (shift_held) c = kbd_shift_char(c);
    kbd_put(c);
}

bool kbd_ext_pending;

fn void xk_kbd_init()
{
    kbd_init_map();
    irq_table[1] = &irq_kbd;
    xk_puts("[kbd] PS/2 keyboard ready\r\n");
}