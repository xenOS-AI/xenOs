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
struct WlConn { bool used; uint srvfd; uint clifd; uint robj; uint cbid; }
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

fn int wl_find(uint srvfd)
{
    for (int i = 0; i < 4; i++) { if (g_wl[i].used && g_wl[i].srvfd == srvfd) return i; }
    return -1;
}
fn void wl_register(uint srvfd, uint clifd)
{
    for (int i = 0; i < 4; i++) { if (!g_wl[i].used) { g_wl[i].used = true; g_wl[i].srvfd = srvfd; g_wl[i].clifd = clifd; g_wl[i].robj = 0; g_wl[i].cbid = 0; return; } }
}

// Drain+answer one server connection (called from lx_sock_write after the client wrote).
fn void wl_serve(int wix)
{
    uint clifd = g_wl[wix].clifd;
    uint srvfd = g_wl[wix].srvfd;
    SockState* s = &g_sock[srvfd];
    while (s.len >= 8)
    {
        uint obj = wl_rd32(s, 0);
        uint op  = wl_rd16(s, 4);
        uint ms  = wl_rd16(s, 6);
        if (ms < 8 || s.len < ms) break;
        if (obj == 1u && op == WLD_GET_REGISTRY && ms >= 12)   // get_registry(new_id)
        {
            uint reg = wl_rd32(s, 8);
            g_wl[wix].robj = reg;
            wl_emit_global(clifd, reg, 1, "wl_compositor", 4);
            wl_emit_global(clifd, reg, 2, "wl_shm", 1);
        }
        else if (obj == 1u && op == WLD_SYNC && ms >= 12)      // sync(new_id callback)
        {
            uint cb = wl_rd32(s, 8);
            g_wl[wix].cbid = cb;
            wl_emit_cb_done(clifd, cb);
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