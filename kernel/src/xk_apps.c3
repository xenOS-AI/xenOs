module xk;

// ============================================================================
// xenOS GUI apps: terminal, clock, and an animated demo.
// Apps render into the shadow framebuffer at their content rect and blit only
// their own (small) damaged region, so VRAM traffic stays bounded.
// ============================================================================

// ---- number formatting (HH:MM:SS style) ----
fn void fmt2(char* out, int v)
{
    out[0] = (char)('0' + v / 10);
    out[1] = (char)('0' + v % 10);
}

// ============================= CLOCK ========================================
const int CLK_W = 176;
const int CLK_H = 52;

fn void app_clock_draw(Window* w)
{
    int ox = w.x;
    int oy = w.y + TITLE_H;
    int secs = (int)(g_ticks / 100);
    int hh = (secs / 3600) % 24;
    int mm = (secs / 60) % 60;
    int ss = secs % 60;
    char[9] t;
    fmt2(&t[0], hh); t[2] = ':';
    fmt2(&t[3], mm); t[5] = ':';
    fmt2(&t[6], ss); t[8] = 0;
    fb_text(ox + 24, oy + 6, &t[0], 0xE0E0E0, fb_rgb(20, 22, 28));
}

fn void app_clock_update()
{
    for (int i = 0; i < WIN_MAX; i++)
    {
        Window* w = &xk_ws[i];
        if (w.open && w.draw == &app_clock_draw)
        {
            app_clock_draw(w);
            fb_blit_rect(w.x, w.y + TITLE_H, w.w, w.h - TITLE_H);
        }
    }
}

// ============================= DEMO =========================================
const int DEMO_W = 200;
const int DEMO_H = 130;

fn void app_demo_draw(Window* w)
{
    int ox = w.x;
    int oy = w.y + TITLE_H;
    int t = (int)(g_ticks / 2);
    // animated bouncing ball
    int cx = 20 + (t % (DEMO_W - 40));
    int cy = 20 + ((t * 3) % (DEMO_H - 50));
    uint col = fb_rgb((t & 0x3ff), (t & 0x7ff) >> 3, (t & 0xff) * 2);
    fb_fill_rect(ox + cx - 8, oy + cy - 8, 16, 16, col);
    fb_text(ox + 4, oy + DEMO_H - 14, "xenOS demo", 0x9AA0A8, fb_rgb(20, 22, 28));
}

fn void app_demo_update()
{
    for (int i = 0; i < WIN_MAX; i++)
    {
        Window* w = &xk_ws[i];
        if (w.open && w.draw == &app_demo_draw)
        {
            app_demo_draw(w);
            fb_blit_rect(w.x, w.y + TITLE_H, w.w, w.h - TITLE_H);
        }
    }
}

// ========================== TERMINAL ========================================
const int TERM_CW = 36;      // columns
const int TERM_RW = 14;      // rows
const int TERM_W = TERM_CW * 8 + 8;
const int TERM_H = TERM_RW * 8 + TITLE_H + 8;
char[TERM_CW * TERM_RW] term_buf;
int term_row;
int term_col;
char[TERM_CW] term_cmd;   // current command line (shell)
int term_cmd_len;

// render a string into the terminal grid AND mirror it to serial (headless).
fn void term_puts(char* s)
{
    while (*s != 0)
    {
        char c = *s;
        term_put(c);
        if (c == '\n') { xk_serial_putc('\r'); xk_serial_putc('\n'); }
        else { xk_serial_putc(c); }
        s++;
    }
}

fn void term_putdec(int v)
{
    char[16] b;
    int n = 0;
    if (v == 0) { term_put('0'); xk_serial_putc('0'); return; }
    if (v < 0)  { term_put('-'); xk_serial_putc('-'); v = -v; }
    while (v > 0) { b[n] = (char)('0' + (v % 10)); n++; v /= 10; }
    for (int i = n - 1; i >= 0; i--) { term_put(b[i]); xk_serial_putc(b[i]); }
}

fn void term_puthex(ulong v)
{
    term_put('0'); xk_serial_putc('0');
    term_put('x'); xk_serial_putc('x');
    for (int shift = 60; shift >= 0; shift -= 4)
    {
        int d = (int)((v >> shift) & 0xF);
        char c = (char)(d < 10 ? ('0' + d) : ('a' + (d - 10)));
        term_put(c);
        xk_serial_putc(c);
    }
}

fn void term_clear()
{
    for (int i = 0; i < TERM_CW * TERM_RW; i++)
    {
        term_buf[i] = 0;
    }
    term_row = 0;
    term_col = 0;
    term_cmd_len = 0;
    term_cmd[0] = 0;
    term_put('>');
}

fn void app_term_draw(Window* w)
{
    int ox = w.x + 4;
    int oy = w.y + TITLE_H + 4;
    for (int r = 0; r < TERM_RW; r++)
    {
        for (int c = 0; c < TERM_CW; c++)
        {
            char ch = term_buf[r * TERM_CW + c];
            char display = ch;
            if (ch == 0) display = ' ';
            fb_char(ox + c * 8, oy + r * 8, display, 0xE8E4D8, fb_rgb(10, 12, 14));
        }
    }
    // cursor
    int ccx = ox + term_col * 8;
    int ccy = oy + term_row * 8;
    fb_fill_rect(ccx, ccy, 8, 8, fb_rgb(80, 200, 120));
}

fn void app_term_key(Window* w, char c)
{
    if (c == '\n' || c == '\r')
    {
        term_cmd[term_cmd_len] = 0;
        term_put('\n');
        if (term_cmd_len > 0) shell_run(&term_cmd[0]);
        term_cmd_len = 0;
        term_cmd[0] = 0;
        term_put('>');
    }
    else if (c == 0x08)
    {
        if (term_cmd_len > 0)
        {
            term_cmd_len--;
            term_cmd[term_cmd_len] = 0;
            term_put(0x08);
        }
    }
    else if (c >= 0x20 && c <= 0x7E)
    {
        if (term_cmd_len < TERM_CW - 1) term_cmd[term_cmd_len++] = c;
        term_put(c);
    }
    // re-render the terminal into the shadow buffer, then blit the damaged region
    app_term_draw(w);
    fb_blit_rect(w.x + 4, w.y + TITLE_H + 4, w.w - 8, (term_row + 1) * 8);
}

fn void term_put(char c)
{
    if (c == '\n' || c == '\r')
    {
        term_col = 0;
        term_row++;
        if (term_row >= TERM_RW) term_scroll();
        return;
    }
    if (c == 0x08)   // backspace
    {
        if (term_col > 0)
        {
            term_col--;
            term_buf[term_row * TERM_CW + term_col] = 0;
        }
        return;
    }
    if (c >= 0x20 && c <= 0x7E)
    {
        term_buf[term_row * TERM_CW + term_col] = c;
        term_col++;
        if (term_col >= TERM_CW)
        {
            term_col = 0;
            term_row++;
            if (term_row >= TERM_RW) term_scroll();
        }
    }
}

fn void term_scroll()
{
    // shift rows up by one
    for (int r = 1; r < TERM_RW; r++)
    {
        for (int c = 0; c < TERM_CW; c++)
        {
            term_buf[(r - 1) * TERM_CW + c] = term_buf[r * TERM_CW + c];
        }
    }
    for (int c = 0; c < TERM_CW; c++) term_buf[(TERM_RW - 1) * TERM_CW + c] = 0;
    term_row = TERM_RW - 1;
}

// ========================= REGISTRATION =====================================
fn void wm_register_apps()
{
    int t = wm_alloc();
    xk_ws[t].x = 40; xk_ws[t].y = 40;
    xk_ws[t].w = TERM_W; xk_ws[t].h = TERM_H;
    xk_ws[t].draw = &app_term_draw;
    xk_ws[t].key = &app_term_key;
    xmcopy(&title_term[0], &xk_ws[t].title[0]);
    xk_active = t;
    shell_banner();      // welcome text into the terminal (also serial)
    term_cmd_len = 0;
    term_put('>');       // initial prompt

    int c = wm_alloc();
    xk_ws[c].x = 560; xk_ws[c].y = 40;
    xk_ws[c].w = CLK_W; xk_ws[c].h = CLK_H;
    xk_ws[c].draw = &app_clock_draw;
    xk_ws[c].key = null;
    xmcopy(&title_clock[0], &xk_ws[c].title[0]);

    int d = wm_alloc();
    xk_ws[d].x = 560; xk_ws[d].y = 110;
    xk_ws[d].w = DEMO_W; xk_ws[d].h = DEMO_H;
    xk_ws[d].draw = &app_demo_draw;
    xk_ws[d].key = null;
    xmcopy(&title_demo[0], &xk_ws[d].title[0]);

    wm_composite();
    wm_present_all();
}

fn void xmcopy(char* src, char* dst)
{
    while (*src != 0)
    {
        *dst = *src;
        dst++;
        src++;
    }
    *dst = 0;
}

char[22] title_term  = {'T','e','r','m','i','n','a','l',' ','[','s','h',']',0,0,0,0,0,0,0,0,0};
char[22] title_clock = {'C','l','o','c','k',0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
char[22] title_demo  = {'D','e','m','o',0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};