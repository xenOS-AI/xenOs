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
struct WlConn { bool used; uint srvfd; uint clifd; uint robj; uint cbid;
                uint shm_id, comp_id, surf_id, pool_id, seat_id, kb_id;
                uint buf_base, bw, bh, bstride; bool attached; }
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

fn int wl_find(uint srvfd)
{
    for (int i = 0; i < 4; i++) { if (g_wl[i].used && g_wl[i].srvfd == srvfd) return i; }
    return -1;
}
fn void wl_register(uint srvfd, uint clifd)
{
    for (int i = 0; i < 4; i++) { if (!g_wl[i].used) { g_wl[i].used = true; g_wl[i].srvfd = srvfd; g_wl[i].clifd = clifd; g_wl[i].robj = 0; g_wl[i].cbid = 0; g_wl[i].shm_id = 0; g_wl[i].comp_id = 0; g_wl[i].seat_id = 0; g_wl[i].kb_id = 0; return; } }
}

// Read a Wayland wire string arg at ring offset `o` (u32 len + bytes + NUL pad);
// returns the padded byte count consumed so the caller can locate the next arg.
fn uint wl_str_len(SockState* s, ulong o)
{
    uint l = wl_rd32(s, o);
    return 4 + ((l + 3u) & ~3u);      // u32 len + padded bytes
}

// Present the attached buffer to the primary framebuffer (Phase D).
fn void wl_present(int wix)
{
    uint w = g_wl[wix].bw;
    uint h = g_wl[wix].bh;
    uint stride = g_wl[wix].bstride;
    ulong base = g_wl[wix].buf_base;
    if (w == 0 || h == 0 || base == 0) return;
    uint fbw = (uint)g_fb_w;
    uint fbh = (uint)g_fb_h;
    uint cx = w < fbw ? w : fbw;
    uint cy = h < fbh ? h : fbh;
    char* fb = (char*)(ulong)0xFD000000ul;
    for (uint yy = 0; yy < cy; yy++)
    {
        char* src = (char*)base + (ulong)yy * (ulong)stride;
        char* dst = fb + (ulong)yy * (ulong)fbw * 4ul;
        for (uint xx = 0; xx < cx * 4u; xx++) dst[xx] = src[xx];
    }
    xk_puts("[wl] PRESENTED "); xk_putdec((int)w); xk_puts("x"); xk_putdec((int)h);
    xk_puts(" stride="); xk_putdec((int)stride); xk_puts(" @"); xk_puthex(base);
    xk_puts(" -> framebuffer\n");
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
            c.surf_id = wl_rd32(s, 8);
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
        else if (obj == c.shm_id && op == WLS_POOL && ms >= 20)
        {
            c.pool_id = wl_rd32(s, 8);
            c.buf_base = wl_rd32(s, 12);      // "fd" transport: the SHM pixel base (single-proc)
            c.bw = 0; c.bh = 0;
        }
        else if (obj == c.pool_id && op == WLP_BUFFER && ms >= 32)
        {
            c.bw = wl_rd32(s, 16);
            c.bh = wl_rd32(s, 20);
            c.bstride = wl_rd32(s, 24);
            c.buf_base += wl_rd32(s, 12);     // offset
        }
        else if (obj == c.surf_id && op == WLSURF_ATTACH && ms >= 20)
        {
            c.attached = true;
        }
        else if (obj == c.surf_id && op == WLSURF_COMMIT && ms >= 8)
        {
            if (c.attached) wl_present(wix);
            c.attached = false;
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