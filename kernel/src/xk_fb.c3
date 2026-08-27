module xk;

// ---- Framebuffer graphics: shadow buffer (fast RAM) + VRAM blit ----
const int FB_W = 800;
const int FB_H = 600;
const ulong VRAM = 0xFD000000;      // QEMU stdvga linear framebuffer
const ulong SHADOW = 0x02000000;    // free RAM >= this address

// pixel colour helpers (0x00RRGGBB)
fn uint fb_rgb(int r, int g, int b) { return (uint)((r << 16) | (g << 8) | b); }

fn void fb_pixel(int x, int y, uint c)
{
    if (x < 0 || x >= FB_W || y < 0 || y >= FB_H) return;
    ((uint*)SHADOW)[y * FB_W + x] = c;
}

fn void fb_blit_rect(int x, int y, int w, int h)
{
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x + w > FB_W) w = FB_W - x;
    if (y + h > FB_H) h = FB_H - y;
    if (w <= 0 || h <= 0) return;
    uint* src = (uint*)SHADOW + (y * FB_W + x);
    uint* dst = (uint*)VRAM + (y * FB_W + x);
    for (int r = 0; r < h; r++)
    {
        // copy one row
        ulong s = (ulong)(src + (ulong)r * FB_W);
        ulong d = (ulong)(dst + (ulong)r * FB_W);
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
    fb_fill_rect(0, 0, FB_W, FB_H, c);
    fb_blit_rect(0, 0, FB_W, FB_H);
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

// small arrow cursor drawn into the shadow buffer at (x, y)
fn void fb_cursor(int cx, int cy)
{
    for (int y = 0; y < 12; y++)
    {
        for (int x = 0; x < 9; x++)
        {
            bool on = false;
            if (y == 0 && x == 0) on = true;
            if (y > 0)
            {
                int roww = y < 6 ? (y > 0 ? 1 : 0) : 0;
                if (x <= (y < 6 ? 0 : (y - 6) * 2)) on = true;
            }
            uint color = on ? 0xFFFFFF : 0x000000;
            // only over non-black cursor area
            fb_pixel(cx + x, cy + y, color);
        }
    }
}