module ai_mock;
// ============================================================================
// xenOS host mock AI provider — a freestanding C3 server (no libc).
// Listens on TCP port 9080 (0.0.0.0), accepts one connection, reads the HTTP
// request, and replies with a realistic OpenAI-style chat/completions JSON.
// This is the local provider that QEMU's hostfwd(9080->10.0.2.15:9080) exposes
// to the guest at 10.0.2.2:9080, so the xenOS chat box talks to a REAL server
// over a REAL (slirp) network — the plan's local-path milestone.
//   Run on the host:   ./build/ai_mock [port]
// ============================================================================

const long SOCK_AF_INET  = 2;
const long SOCK_STREAM   = 1;
const long SOCK_PROTO    = 0;
const long INADDR_ANY    = 0;

extern fn long lx_syscall(long n, long a, long b, long c, long d);

// --- Linux syscalls (via host_start.asm) ---
fn long sc_socket()          { return lx_syscall(41, SOCK_AF_INET, SOCK_STREAM, SOCK_PROTO, 0); }
fn long sc_bind(long fd, long a, long len)   { return lx_syscall(49, fd, a, len, 0); }
fn long sc_listen(long fd, long backlog)     { return lx_syscall(50, fd, backlog, 0, 0); }
fn long sc_accept(long fd, long a, long b)   { return lx_syscall(43, fd, a, b, 0); }
fn long sc_read(long fd, char* b, long n)    { return lx_syscall(0, fd, (long)b, n, 0); }
fn long sc_write(long fd, char* b, long n)   { return lx_syscall(1, fd, (long)b, n, 0); }
fn long sc_close(long fd)                    { return lx_syscall(3, fd, 0, 0, 0); }

fn void* memset(void* dst, int val, ulong n) @export("memset")
{
    char* p = (char*)dst;
    for (ulong i = 0; i < n; i++) { p[i] = (char)val; }
    return dst;
}

fn void* memcpy(void* dst, void* src, ulong n) @export("memcpy")
{
    char* d = (char*)dst;
    char* s = (char*)src;
    for (ulong i = 0; i < n; i++) { d[i] = s[i]; }
    return dst;
}

fn ulong strlen(char* s) @export("strlen")
{
    ulong n = 0;
    while (s[n] != 0) n++;
    return n;
}

fn long cstrlen(char* s)
{
    long n = 0;
    while (s[n] != 0) n++;
    return n;
}

fn void put_u16(char* b, long off, long v){ b[off]=(char)((v>>8)&0xFF); b[off+1]=(char)(v&0xFF); }
fn void put_u32(char* b, long off, long v){ b[off]=(char)((v>>24)&0xFF); b[off+1]=(char)((v>>16)&0xFF); b[off+2]=(char)((v>>8)&0xFF); b[off+3]=(char)(v&0xFF); }

// Leet the server print a short status to stderr.
fn void say(char* s, long n) { sc_write(2, s, n); }

fn int xk_host_main(int argc, char** argv) @export("xk_host_main")
{
    long port = 9080;
    if (argc > 1)
    {
        long p = 0;
        char* s = argv[1];
        for (int i = 0; s[i] != 0; i++)
        {
            if (s[i] >= '0' && s[i] <= '9') { p = p * 10 + (long)(s[i] - '0'); }
        }
        if (p > 0) port = p;
    }
    say((char*)"ai_mock: listening on 0.0.0.0:", 30);
    char[16] num; int nn = 0; long pv = port;
    while (pv > 0) { num[nn++] = (char)('0' + (pv % 10)); pv /= 10; }
    for (int i = nn - 1; i >= 0; i--) sc_write(2, &num[i], 1);
    say((char*)"\n", 1);

    long sfd = sc_socket();
    if (sfd < 0) { say((char*)"ai_mock: socket failed\n", 23); return 1; }

    char[16] sa;
    memset(&sa[0], 0, 16);
    sa[0] = (char)(SOCK_AF_INET & 0xFF);    // sin_family is HOST byte order (LE)
    sa[1] = (char)((SOCK_AF_INET >> 8) & 0xFF);
    put_u16(&sa[0], 2, port);              // sin_port is NETWORK byte order (BE)
    put_u32(&sa[0], 4, INADDR_ANY);
    long br = sc_bind(sfd, (long)&sa[0], 16);
    if (br != 0)
    {
        // show the bind return (-errno) on stderr for diagnosis
        long neg = -br;
        sc_write(2, (char*)"ai_mock: bind returned: ", 24);
        char[10] dgt; int dc = 0; long dv = neg;
        while (dv > 0) { dgt[dc++] = (char)('0' + (dv % 10)); dv /= 10; }
        for (int i = dc - 1; i >= 0; i--) sc_write(2, &dgt[i], 1);
        sc_write(2, (char*)"\n", 1);
        return 1;
    }
    if (sc_listen(sfd, 1) != 0) { say((char*)"ai_mock: listen failed\n", 23); return 1; }
    say((char*)"ai_mock: ready, accept loop\n", 28);

    int served = 0;
    while (true)
    {
        long cfd = sc_accept(sfd, 0, 0);
        if (cfd < 0) continue;
        say((char*)"ai_mock: accepted a connection\n", 30);
        // read the HTTP request (up to 8K)
        char[8192] buf;
        long n = sc_read(cfd, &buf[0], 8192);
        if (n > 0)
        {
            // craft the response
            const char* BODY = "{\"choices\":[{\"message\":{\"role\":\"assistant\","
                               "\"content\":\"Hello from the host mock AI provider! "
                               "xenOS reached me over QEMU networking (10.0.2.2 hostfwd to 9080).\"}}]}";
            long blen = cstrlen((char*)BODY);
            char[512] hdr;
            long o = 0;
            const char* STATUS = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
            for (long i = 0; STATUS[i] != 0; i++) hdr[o++] = STATUS[i];
            char[12] lb; int ln = 0; long lv = blen;
            while (lv > 0) { lb[ln++] = (char)('0' + (lv % 10)); lv /= 10; }
            for (int i = ln - 1; i >= 0; i--) hdr[o++] = lb[i];
            const char* CRLF = "\r\nConnection: close\r\n\r\n";
            for (long i = 0; CRLF[i] != 0; i++) hdr[o++] = CRLF[i];
            sc_write(cfd, &hdr[0], o);
            sc_write(cfd, (char*)BODY, blen);
            served++;
            say((char*)"ai_mock: served a request, content replied\n", 42);
        }
        sc_close(cfd);
    }
    return 0;
}