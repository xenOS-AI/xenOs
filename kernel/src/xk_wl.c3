module xk;

// ============================================================================
// xenOS kernel Wayland compositor (Phase D) - the interop gate.
// Speaks the REAL Wayland wire protocol on /run/wayland-0 to libwayland-client:
//   wl_display.get_registry -> advertise wl_compositor + wl_shm globals
//   wl_display.sync         -> wl_callback.done  (client's wl_display_roundtrip returns)
// Surface attach/present is the next increment on top of this framing.
// ============================================================================

// Wire opcodes (core protocol):
const uint WLD_SYNC        = 0;   // wl_display.sync (new_id callback)
const uint WLD_GET_REGISTRY= 1;   // wl_display.get_registry (new_id registry)
const uint WLREG_BIND      = 0;   // wl_registry.bind
const uint WLREG_GLOBAL    = 0;   // event
// wl_compositor/wl_shm/wl_shm_pool/wl_surface requests:
const uint WLC_SURFACE = 0;       // wl_compositor.create_surface
const uint WLS_POOL    = 0;       // wl_shm.create_pool
const uint WLP_BUFFER  = 0;       // wl_shm_pool.create_buffer
const uint WLSURF_ATTACH = 1;     // wl_surface.attach
const uint WLSURF_COMMIT = 6;     // wl_surface.commit
const uint WLSEAT_KB = 1;         // wl_seat.get_keyboard (new_id)
const uint WLSEAT_PTR = 2;        // wl_seat.get_pointer (new_id)
const uint WLSURF_FRAME  = 3;     // wl_surface.frame (new_id callback)
struct WlSur { bool used; uint surf_id; uint buf_base, bw, bh, bstride; bool attached; uint frame_cb; }
struct WlConn { bool used; uint srvfd; uint clifd; uint robj; uint cbid;
                uint shm_id, comp_id, surf_id, pool_id, seat_id, kb_id, ptr_id;
                uint curw; WlSur[4] surfs; }
WlConn[4] g_wl;
uint g_wl_serial = 1;

fn void wl_u16(char* b, uint o, uint v) { b[o] = (char)(v & 0xFF); b[o + 1] = (char)((v >> 8) & 0xFF); }
fn void wl_u32(char* b, uint o, uint v) { b[o] = (char)(v & 0xFF); b[o+1] = (char)((v>>8)&0xFF); b[o+2] = (char)((v>>16)&0xFF); b[o+3] = (char)((v>>24)&0xFF); }
fn uint wl_byte(SockState* s, ulong i)
{
    ulong bq = s.buf;
    char* p = (char*)bq;
    ulong o = (s.pos + i) % s.cap;
    char c = p[o];
    return (uint)c & 0xFFu;
}
fn uint wl_rd16(SockState* s, ulong i) { return wl_byte(s, i) | (wl_byte(s, i + 1) << 8); }
fn uint wl_rd32(SockState* s, ulong i) { return wl_rd16(s, i) | (wl_rd16(s, i + 2) << 16); }

// flag fo...
fn void wl_pop(SockState* s, ulong n) { s.pos = (s.pos + n) % s.cap; s.len -= n; }
fn void wl_emit(uint clifd, char* b, uint n)
{
    SockState* c = &g_sock[clifd];
    for (uint i = 0; i < n; i++)
    {
        if (c.len >= c.cap) break;
        ulong bq = c.buf;
        char* p = (char*)bq;
        p[(c.pos + c.len) % c.cap] = b[i];
        c.len++;
    }
    up_wake_all();
}
fn void wl_emit_global(uint clifd, uint reg, uint name, char* iface, uint ver)
{
    uint ilen = 0; while (iface[ilen]) ilen++;
    uint pad = (4u - (ilen % 4u)) % 4u;
    uint msz = 8 + 4 + 4 + ilen + pad + 4;
    char[64] b;
    wl_u32(&b[0], 0, reg); wl_u16(&b[0], 4, WLREG_GLOBAL); wl_u16(&b[0], 6, msz);
    wl_u32(&b[0], 8, name);
    wl_u32(&b[0], 12, ilen);
    char* bp = &b[0];
    for (uint k = 0; k < ilen; k++) bp[16 + k] = iface[k];
    for (uint k = 0; k < pad; k++) bp[16 + ilen + k] = (char)0;
    wl_u32(&b[0], 16 + ilen + pad, ver);
    wl_emit(clifd, &b[0], msz);
}
fn void wl_emit_cb_done(uint clifd, uint cb)
{
    char[12] b;
    wl_u32(&b[0], 0, cb); wl_u16(&b[0], 4, 0); wl_u16(&b[0], 6, 12);
    wl_u32(&b[0], 8, g_wl_serial++);
    wl_emit(clifd, &b[0], 12);
}
// wl_keyboard.key event (object kb, op 4): serial, time, key, state
fn void wl_emit_key(uint clifd, uint kb, uint key, uint state)
{
    char[24] b;
    wl_u32(&b[0], 0, kb); wl_u16(&b[0], 4, 4); wl_u16(&b[0], 6, 24);
    wl_u32(&b[0], 8, g_wl_serial++); wl_u32(&b[0], 12, 0);
    wl_u32(&b[0], 16, key); wl_u32(&b[0], 20, state);
    wl_emit(clifd, &b[0], 24);
}

// wl_pointer.motion event (op0): time, x fixed, y fixed
fn void wl_emit_ptr_motion(uint clifd, uint ptr, uint x, uint y)
{
    char[20] b;
    wl_u32(&b[0], 0, ptr); wl_u16(&b[0], 4, 0); wl_u16(&b[0], 6, 20);
    wl_u32(&b[0], 8, g_wl_serial++); wl_u32(&b[0], 12, x); wl_u32(&b[0], 16, y);
    wl_emit(clifd, &b[0], 20);
}
// wl_pointer.button event (op2): serial, time, button, state
fn void wl_emit_ptr_button(uint clifd, uint ptr, uint btn)
{
    char[24] b;
    wl_u32(&b[0], 0, ptr); wl_u16(&b[0], 4, 2); wl_u16(&b[0], 6, 24);
    wl_u32(&b[0], 8, g_wl_serial++); wl_u32(&b[0], 12, 0); wl_u32(&b[0], 16, btn); wl_u32(&b[0], 20, 1);
    wl_emit(clifd, &b[0], 24);
}
fn int wl_find(uint srvfd)
{
    for (int i = 0; i < 4; i++) { if (g_wl[i].used && g_wl[i].srvfd == srvfd) return i; }
    return -1;
}
fn void wl_register(uint srvfd, uint clifd)
{
    for (int i = 0; i < 4; i++) { if (!g_wl[i].used) { g_wl[i].used = true; g_wl[i].srvfd = srvfd; g_wl[i].clifd = clifd; g_wl[i].robj = 0; g_wl[i].cbid = 0; g_wl[i].shm_id = 0; g_wl[i].comp_id = 0; g_wl[i].seat_id = 0; g_wl[i].kb_id = 0; g_wl[i].ptr_id = 0; g_wl[i].curw = 0; for (int k = 0; k < 4; k++) { g_wl[i].surfs[k].used = false; } return; } }
}

// Read a Wayland wire string arg at ring offset `o` (u32 len + bytes + NUL pad);
// returns the padded byte count consumed so the caller can locate the next arg.
fn uint wl_str_len(SockState* s, ulong o)
{
    uint l = wl_rd32(s, o);
    return 4 + ((l + 3u) & ~3u);      // u32 len + padded bytes
}

// Present the attached buffer to the primary framebuffer (Phase D).
fn int wl_find_surf(WlConn* c, uint id)
{
    for (int i = 0; i < 4; i++) { if (c.surfs[i].used && c.surfs[i].surf_id == id) return i; }
    return -1;
}
// Present surface `si` tiled across the framebuffer (a basic window manager).
fn void wl_present(int wix, int si)
{
    WlSur* q = &g_wl[wix].surfs[si];
    uint w = q.bw;
    uint h = q.bh;
    uint stride = q.bstride;
    ulong base = q.buf_base;
    if (w == 0 || h == 0 || base == 0) return;
    uint fbw = (uint)g_fb_w;
    uint fbh = (uint)g_fb_h;
    uint x0 = (uint)(si % 2) * 336u;
    uint y0 = (uint)(si / 2) * 256u;
    uint cx = w < (fbw - x0) ? w : (fbw - x0);
    uint cy = h < (fbh - y0) ? h : (fbh - y0);
    char* fb = (char*)(ulong)0xFD000000ul;
    for (uint yy = 0; yy < cy; yy++)
    {
        char* src = (char*)base + (ulong)yy * (ulong)stride;
        char* dst = fb + ((ulong)(yy + y0) * (ulong)fbw + (ulong)x0) * 4ul;
        for (uint xx = 0; xx < cx * 4u; xx++) dst[xx] = src[xx];
    }
    xk_puts("[wl] PRESENTED win"); xk_putdec(si); xk_puts(" "); xk_putdec((int)w); xk_puts("x"); xk_putdec((int)h);
    xk_puts(" @"); xk_puthex(base); xk_puts(" at "); xk_putdec((int)x0); xk_puts(","); xk_putdec((int)y0);
    xk_puts("\n");
}

// Map a PS/2-derived ASCII char (kbd queue) to a Linux evdev keycode for the wire.
uint[26] wl_letters = {30,48,46,32,18,33,34,35,23,36,37,38,50,49,24,25,16,19,31,20,22,47,17,45,21,44};
fn uint wl_asc_keycode(char c)
{
    if (c >= 'a' && c <= 'z') return wl_letters[(uint)c - 0x61u];
    if (c >= '1' && c <= '9') return (uint)(2 + (c - '1'));
    if (c == '0') return 11;
    if (c == ' ') return 57;
    if (c == '\n') return 28;
    return 0;
}
fn void wl_serve(int wix)
{
    uint clifd = g_wl[wix].clifd;
    uint srvfd = g_wl[wix].srvfd;
    SockState* s = &g_sock[srvfd];
    WlConn* c = &g_wl[wix];
    while (s.len >= 8)
    {
        uint obj = wl_rd32(s, 0);
        uint op  = wl_rd16(s, 4);
        uint ms  = wl_rd16(s, 6);
        if (ms < 8 || s.len < ms) break;
        if (obj == 1u && op == WLD_GET_REGISTRY && ms >= 12)
        {
            c.robj = wl_rd32(s, 8);
            wl_emit_global(clifd, c.robj, 1, "wl_compositor", 4);
            wl_emit_global(clifd, c.robj, 2, "wl_shm", 1);
            wl_emit_global(clifd, c.robj, 3, "wl_seat", 6);
        }
        else if (obj == c.robj && obj >= 2u && op == WLREG_BIND && ms >= 24)
        {
            uint name = wl_rd32(s, 8);
            uint ilen = wl_rd32(s, 12) & 0xFFu;
            uint peek = wl_byte(s, 16);
            uint impl = wl_byte(s, 16 + 1);
            uint id = wl_rd32(s, (ulong)(12u + wl_str_len(s, 12) + 4u));   // name,str,version,new_id
            if (name == 2u && peek == 'w' && impl == 'l') { c.shm_id = id; }
                        else if (name == 1u && peek == 'w') { c.comp_id = id; }
                        else if (name == 3u) { c.seat_id = id; }
        }
        else if (obj == c.comp_id && op == WLC_SURFACE && ms >= 12)
        {
            uint sid = wl_rd32(s, 8);
            for (int i = 0; i < 4; i++) { if (!c.surfs[i].used) { c.surfs[i].used = true; c.surfs[i].surf_id = sid; c.surfs[i].bw = 0; c.surfs[i].attached = false; c.surfs[i].frame_cb = 0; c.curw = (uint)i; break; } }
        }
        else if (obj == c.seat_id && op == WLSEAT_KB && ms >= 12)
        {
            c.kb_id = wl_rd32(s, 8);
            // drain the REAL kernel keyboard queue (PS/2-derived chars -> evdev keycodes)
            while (kbd_has())
            {
                uint kc = wl_asc_keycode(kbd_pop());
                if (kc != 0) { wl_emit_key(clifd, c.kb_id, kc, 1u); wl_emit_key(clifd, c.kb_id, kc, 0u); }
            }
        }
        else if (obj == c.seat_id && op == WLSEAT_PTR && ms >= 12)
        {
            c.ptr_id = wl_rd32(s, 8);
            uint fx = (uint)((ulong)mouse_x << 16);     // wl_fixed from the LIVE PS/2-derived state
            uint fy = (uint)((ulong)mouse_y << 16);
            wl_emit_ptr_motion(clifd, c.ptr_id, fx, fy);
            if ((mouse_buttons & 1u) != 0) wl_emit_ptr_button(clifd, c.ptr_id, 0x110u);
        }
        else if (obj == c.shm_id && op == WLS_POOL && ms >= 20)
                {
                    c.pool_id = wl_rd32(s, 8);
                    c.surfs[c.curw].buf_base = wl_rd32(s, 12);   // "fd" transport: SHM pixel base (single-proc)
                }
                else if (obj == c.pool_id && op == WLP_BUFFER && ms >= 32)
                {
                    c.surfs[c.curw].bw = wl_rd32(s, 16);
                    c.surfs[c.curw].bh = wl_rd32(s, 20);
                    c.surfs[c.curw].bstride = wl_rd32(s, 24);
                    c.surfs[c.curw].buf_base += wl_rd32(s, 12);   // offset
                }
                else if (op == WLSURF_ATTACH && ms >= 20)
                {
                    int si = wl_find_surf(c, obj);
                    if (si >= 0) c.surfs[si].attached = true;
                }
                else if (op == WLSURF_FRAME && ms >= 12)
                        {
                            int si = wl_find_surf(c, obj);
                            if (si >= 0) c.surfs[si].frame_cb = wl_rd32(s, 8);
                        }
                        else if (op == WLSURF_COMMIT && ms >= 8)
                        {
                            int si = wl_find_surf(c, obj);
                            if (si >= 0)
                            {
                                if (c.surfs[si].attached) wl_present(wix, si);
                                c.surfs[si].attached = false;
                                if (c.surfs[si].frame_cb != 0) { wl_emit_cb_done(clifd, c.surfs[si].frame_cb); c.surfs[si].frame_cb = 0; }
                            }
                        }
        wl_pop(s, ms);
    }
}
fn void wl_serve_peer(uint peer)
{
    int wix = wl_find(peer);
    if (wix >= 0) wl_serve(wix);
}

// Bind + listen the compositor socket before the client runs.
fn void wl_compositor_init()
{
    int lfd = -1;
    for (int i = 3; i < MAX_FDS; i++) { if (!g_fd[i].used) { lfd = i; break; } }
    if (lfd < 0) return;
    int i = 0; char* t = (char*)"/run/wayland-0"; while (i < 23 && t[i]) { g_sock[lfd].spath[i] = t[i]; i++; } g_sock[lfd].spath[i] = 0;
    g_fd[lfd].used = true; g_fd[lfd].type = FD_SOCK;
    g_sock[lfd].used = true; g_sock[lfd].buf = 0; g_sock[lfd].cap = SOCK_CAP; g_sock[lfd].len = 0; g_sock[lfd].pos = 0; g_sock[lfd].peer = -1; g_sock[lfd].listener = true; g_sock[lfd].pn = 0;
    xk_puts("[wl] kernel compositor listening on /run/wayland-0\n");
}