module xk;

// ============================================================================
// xenOS window manager & display server ("X-equivalent").
// Compositor over the shadow framebuffer with per-window repaint + dirty blits.
// Windows are tiny callbacks; apps render into the shadow and mark damage.
// ============================================================================

const int WMW = FB_W;
const int WMH = FB_H;
const int TITLE_H = 20;
const int DOCK_H = 30;
const int WIN_MAX = 8;

alias AppDraw = fn void(Window* w);
alias AppKey  = fn void(Window* w, char c);

struct Window
{
    bool  open;
    int   x, y, w, h;
    char[22] title;
    AppDraw draw;
    AppKey  key;
    int     dirty;          // non-zero => content needs repaint on next present
    int[8]  state;          // per-app scratch
}

Window[WIN_MAX] xk_ws;
int  xk_active = -1;
int  wm_drag = -1;
int  drag_dx, drag_dy;
int  prev_buttons;

uint col_title_bg;
uint col_title_fg;

// ---- window pool helpers ----
fn int wm_alloc()
{
    for (int i = 0; i < WIN_MAX; i++)
    {
        if (!xk_ws[i].open)
        {
            xk_ws[i].open = true;
            return i;
        }
    }
    return -1;
}

fn void wm_titlebar(Window* w, bool active)
{
    uint bar = active ? fb_rgb(70, 130, 220) : fb_rgb(55, 65, 80);
    fb_fill_rect(w.x, w.y, w.w, TITLE_H, bar);
    fb_text(w.x + 4, w.y + 6, &w.title[0], 0xFFFFFF, bar);
    // close button (top-right 16x16)
    fb_fill_rect(w.x + w.w - 18, w.y + 2, 16, 16, fb_rgb(200, 60, 60));
    fb_text(w.x + w.w - 14, w.y + 6, "X", 0xFFFFFF, fb_rgb(200, 60, 60));
}

// redraw ONE window (chrome + content) into the shadow buffer
fn void wm_draw_window(int i)
{
    Window* w = &xk_ws[i];
    if (!w.open) return;
    // content background
    fb_fill_rect(w.x, w.y + TITLE_H, w.w, w.h - TITLE_H, fb_rgb(20, 22, 28));
    if (w.draw != null)
    {
        w.draw(w);            // app draws its content at (w.x, w.y+TITLE_H)
    }
    wm_titlebar(w, i == xk_active);
}

// composite ALL windows in z-order into the shadow buffer
fn void wm_composite()
{
    // repaint background + dock beneath the windows (avoids ghosting)
    fb_fill_rect(0, 0, WMW, WMH, fb_rgb(16, 32, 48));
    fb_fill_rect(0, WMH - DOCK_H, WMW, DOCK_H, fb_rgb(30, 34, 42));
    for (int i = 0; i < WIN_MAX; i++)
    {
        if (xk_ws[i].open) wm_draw_window(i);
    }
    // dock back on top
    fb_fill_rect(0, WMH - DOCK_H, WMW, DOCK_H, fb_rgb(30, 34, 42));
}

// blit one window's rect to VRAM
fn void wm_present_window(int i)
{
    Window* w = &xk_ws[i];
    if (w.open) fb_blit_rect(w.x, w.y, w.w, w.h);
}

fn void wm_init_colors()
{
    col_title_bg = fb_rgb(70, 130, 220);
    col_title_fg = 0xFFFFFF;
}

// ---- desktop background + dock ----
fn void wm_desktop()
{
    fb_clear(fb_rgb(16, 32, 48));
    // dock
    fb_fill_rect(0, WMH - DOCK_H, WMW, DOCK_H, fb_rgb(30, 34, 42));
    fb_blit_rect(0, 0, WMW, WMH - DOCK_H);
    fb_blit_rect(0, WMH - DOCK_H, WMW, DOCK_H);
}

// ---- hit testing ----
fn int wm_top_window(int x, int y)
{
    for (int i = WIN_MAX - 1; i >= 0; i--)
    {
        Window* w = &xk_ws[i];
        if (w.open && x >= w.x && x < w.x + w.w && y >= w.y && y < w.y + w.h)
        {
            return i;
        }
    }
    return -1;
}

fn bool wm_in_title(int i, int x, int y)
{
    Window* w = &xk_ws[i];
    return y >= w.y && y < w.y + TITLE_H;
}

fn bool wm_in_close(Window* w, int x, int y)
{
    return x >= w.x + w.w - 18 && x < w.x + w.w && y >= w.y && y < w.y + 18;
}

fn bool wm_in_dock(int y)
{
    return y >= WMH - DOCK_H;
}

// ---- bring window to front by reordering ----
fn void wm_to_front(int i)
{
    // rebuild order: keep only open windows, move `i` last
    Window saved = xk_ws[i];
    for (int j = i; j < WIN_MAX - 1; j++)
    {
        xk_ws[j] = xk_ws[j + 1];
    }
    xk_ws[WIN_MAX - 1] = saved;
    xk_active = WIN_MAX - 1;
}

// ---- global event processing, called periodically from the idle loop ----
fn void wm_tick()
{
    int buttons = (int)mouse_buttons;

    if (buttons != prev_buttons)
    {
        xk_puts("[wm] btn ");
        xk_putdec(buttons);
        xk_puts(" prev ");
        xk_putdec(prev_buttons);
        xk_puts(" m=");
        xk_putdec(mouse_x);
        xk_putc(',');
        xk_putdec(mouse_y);
        xk_puts("\r\n");
    }

    // left-button handling (press vs release)
    bool press = (buttons & 1) != 0 && (prev_buttons & 1) == 0;
    bool rel   = (buttons & 1) == 0 && (prev_buttons & 1) != 0;

    if (press)
    {
        if (wm_in_dock(mouse_y))
        {
            // dock area: not implemented yet, ignore
        }
        else
        {
            int w = wm_top_window(mouse_x, mouse_y);
            xk_puts("[wm] press at ");
            xk_putdec(mouse_x);
            xk_putc(',');
            xk_putdec(mouse_y);
            xk_puts(" win=");
            xk_putdec(w);
            xk_puts("\r\n");
            if (w >= 0)
            {
                Window* ww = &xk_ws[w];
                if (wm_in_close(ww, mouse_x, mouse_y))
                {
                    // X marks dispose in a later call to avoid reordering
                    ww.open = false;
                    wm_composite();
                    wm_present_all();
                    xk_active = -1;
                }
                else
                {
                    wm_to_front(w);
                    // move active window to front slot
                    Window* front = &xk_ws[WIN_MAX - 1];
                    if (wm_in_title(WIN_MAX - 1, mouse_x, mouse_y))
                    {
                        wm_drag = WIN_MAX - 1;
                        drag_dx = mouse_x - front.x;
                        drag_dy = mouse_y - front.y;
                        xk_puts("[wm] drag start\r\n");
                    }
                    wm_composite();
                    wm_present_all();
                }
            }
        }
    }
    else if (rel)
    {
        if (wm_drag >= 0) xk_puts("[wm] drag end\r\n");
        wm_drag = -1;
    }

    // dragging
    if (wm_drag >= 0)
    {
        Window* w = &xk_ws[wm_drag];
        w.x = mouse_x - drag_dx;
        w.y = mouse_y - drag_dy;
        if (w.x < 0) w.x = 0;
        if (w.y < 0) w.y = 0;
        if (w.x + w.w > WMW) w.x = WMW - w.w;
        if (w.y + w.h > WMH - DOCK_H) w.y = WMH - DOCK_H - w.h;
        wm_composite();
        wm_present_all();
    }

    prev_buttons = buttons;
}

fn void wm_present_all()
{
    for (int i = 0; i < WIN_MAX; i++)
    {
        if (xk_ws[i].open) wm_present_window(i);
    }
}

// route a keypress to the focused window
fn void wm_key(char c)
{
    if (xk_active >= 0)
    {
        Window* w = &xk_ws[xk_active];
        if (w.key != null) w.key(w, c);
    }
}

fn void wm_init()
{
    wm_init_colors();
    wm_desktop();
    xk_puts("[wm] window manager ready\r\n");
}