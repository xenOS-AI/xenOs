module xk;

// ---- Framebuffer graphics: shadow buffer (fast RAM) + VRAM blit ----
// The framebuffer dimensions are set at runtime from the bootloader's BootInfo
// (fb_setmode), so the display adapts to whatever resolution was negotiated in
// boot/stage1.asm without recompiling the kernel. FB_W/H_MAX bound the shadow
// buffer (which is statically reserved) so it fits for the largest mode.
const int FB_W_MAX = 1920;   // max supported canvas (shadow buffer sized to this)
const int FB_H_MAX = 1080;
int g_fb_w;                  // actual runtime framebuffer width/height/pitch
int g_fb_h;
int g_fb_pitch;
const ulong VRAM = 0xFD000000;      // QEMU stdvga linear framebuffer
const ulong SHADOW = 0x02000000;    // free RAM >= this address

// Adopt the framebuffer geometry negotiated by the bootloader (BootInfo).
fn void fb_setmode(int w, int h, int pitch)
{
    g_fb_w = w;
    g_fb_h = h;
    g_fb_pitch = pitch;
    wmw = w;          // window-manager canvas derives from the runtime screen
    wmh = h;
}

// pixel colour helpers (0x00RRGGBB)
fn uint fb_rgb(int r, int g, int b) { return (uint)((r << 16) | (g << 8) | b); }

fn void fb_pixel(int x, int y, uint c)
{
    if (x < 0 || x >= g_fb_w || y < 0 || y >= g_fb_h) return;
    ((uint*)SHADOW)[y * g_fb_w + x] = c;
}

fn void fb_blit_rect(int x, int y, int w, int h)
{
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x + w > g_fb_w) w = g_fb_w - x;
    if (y + h > g_fb_h) h = g_fb_h - y;
    if (w <= 0 || h <= 0) return;
    int dst_stride = g_fb_pitch >> 2;            // VRAM row length in u32
    uint* dst0 = (uint*)VRAM  + (y * dst_stride + x);
    uint* src0 = (uint*)SHADOW + (y * g_fb_w + x);
    for (int r = 0; r < h; r++)
    {
        ulong s = (ulong)(src0 + (ulong)r * (ulong)g_fb_w);
        ulong d = (ulong)(dst0 + (ulong)r * (ulong)dst_stride);
        for (int c = 0; c < w; c++)
        {
            ((uint*)d)[c] = ((uint*)s)[c];
        }
    }
}

fn void fb_fill_rect(int x, int y, int w, int h, uint c)
{
    for (int j = 0; j < h; j++)
    {
        for (int i = 0; i < w; i++)
        {
            fb_pixel(x + i, y + j, c);
        }
    }
}

fn void fb_clear(uint c)
{
    fb_fill_rect(0, 0, g_fb_w, g_fb_h, c);
    fb_blit_rect(0, 0, g_fb_w, g_fb_h);
}

// ---- text rendering (8x8 bitmap font from xk_font.c3) ----
fn void fb_char(int x, int y, char c, uint fg, uint bg)
{
    if (c < 0x20 || c > 0x7E) c = '?';
    char* glyph = &kfont[0] + (((int)c - 0x20) * 8);
    for (int row = 0; row < 8; row++)
    {
        char bits = glyph[row];
        for (int col = 0; col < 8; col++)
        {
            if ((bits & (1 << (7 - col))) != 0)
            {
                fb_pixel(x + col, y + row, fg);
            }
            else if (bg != 0xFFFFFFFF)   // sentinel = transparent
            {
                fb_pixel(x + col, y + row, bg);
            }
        }
    }
}

fn void fb_text(int x, int y, char* s, uint fg, uint bg)
{
    while (*s != 0)
    {
        fb_char(x, y, *s, fg, bg);
        x += 8;
        s++;
    }
}

// synthetic text with explicit length (for buffers)
fn void fb_textn(int x, int y, char* s, int len, uint fg, uint bg)
{
    for (int i = 0; i < len; i++)
    {
        fb_char(x, y, s[i], fg, bg);
        x += 8;
    }
}

// ---- mouse cursor overlay ----
// Drawn directly into VRAM (not the compositor's shadow) so it stays on top of
// the desktop and never leaves trails: the 12x16 background behind it is
// snapshotted and restored before each redraw. The arrow is rendered white with
// a 1px black drop-shadow so it stays visible on both dark and light surfaces.
int cur_prev_x;   // last drawn position (-1 = not currently drawn; set in init)
int cur_prev_y;
uint[192] cur_bg;      // saved 12x16 background under the cursor

// Arrow body predicate (tip/hotspot at (0,0)). Returns true only inside the
// bitmap; negative or out-of-range indices are NOT part of the arrow.
fn bool cursor_on(int x, int y)
{
    if (x < 0 || y < 0 || x > 9 || y > 13) return false;
    if (y <= 5) return x == 0 || x == 1;       // 2px vertical stem
    if (y == 6) return x <= 1;                 // taper
    return x <= 1 + (y - 6);                   // widening head (to x<=8 at y=13)
}

fn void fb_vram_pixel(int x, int y, uint c)
{
    if (x < 0 || x >= g_fb_w || y < 0 || y >= g_fb_h) return;
    ((uint*)VRAM)[(ulong)y * (ulong)(g_fb_pitch >> 2) + (ulong)x] = c;
}

fn void fb_erase_cursor()
{
    if (cur_prev_x < 0) return;
    int ox = cur_prev_x;
    int oy = cur_prev_y;
    uint dst_stride = (uint)(g_fb_pitch >> 2);
    for (int j = 0; j < 16; j++)
    {
        for (int i = 0; i < 12; i++)
        {
            int fx = ox + i;
            int fy = oy + j;
            if (fx < 0 || fx >= g_fb_w || fy < 0 || fy >= g_fb_h) continue;
            ((uint*)VRAM)[(ulong)fy * (ulong)dst_stride + (ulong)fx] = cur_bg[j * 12 + i];
        }
    }
    cur_prev_x = -1;
}

// arrow cursor drawn directly into VRAM at (cx, cy) (the hotspot/tip).
fn void fb_cursor(int cx, int cy)
{
    fb_erase_cursor();     // restore the desktop where the cursor was

    // snapshot the background where the cursor is about to be drawn
    uint dst_stride = (uint)(g_fb_pitch >> 2);
    for (int j = 0; j < 16; j++)
    {
        for (int i = 0; i < 12; i++)
        {
            int fx = cx + i;
            int fy = cy + j;
            if (fx < 0 || fx >= g_fb_w || fy < 0 || fy >= g_fb_h) { cur_bg[j * 12 + i] = 0; continue; }
            cur_bg[j * 12 + i] = ((uint*)VRAM)[(ulong)fy * (ulong)dst_stride + (ulong)fx];
        }
    }

    // pass 1: black drop-shadow offset (1,1) so the arrow pops on light content
    for (int y = 0; y < 14; y++)
    {
        for (int x = 0; x < 10; x++)
        {
            if (cursor_on(x, y)) fb_vram_pixel(cx + 1 + x, cy + 1 + y, 0u);
        }
    }
    // pass 2: white arrow body at the hotspot
    for (int y = 0; y < 14; y++)
    {
        for (int x = 0; x < 10; x++)
        {
            if (cursor_on(x, y)) fb_vram_pixel(cx + x, cy + y, 0xFFFFFFu);
        }
    }
    cur_prev_x = cx;
    cur_prev_y = cy;
}