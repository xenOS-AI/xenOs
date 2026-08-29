module tls_clienthello;
// ============================================================================
// Emit a minimal TLS 1.2 ClientHello record to stdout, then (optionally) dump
// it for inspection. Used to prove our from-scratch record/ClientHello framing
// interoperates with real OpenSSL: pipe these bytes into `openssl s_server`
// (its -msg output shows it accepted the handshake rather than alerting).
// The framing code is a copy of kernel/src/xk_tls.c3's tls_record/tls_clienthello.
// ============================================================================

extern fn long lx_syscall(long n, long a, long b, long c, long d);
fn long xwrite(long fd, char* b, long n) { return lx_syscall(1, fd, (long)b, n, 0); }

fn void* memset(void* dst, int val, ulong n) @export("memset")
{
    char* p = (char*)dst;
    for (ulong i = 0; i < n; i++) { p[i] = (char)val; }
    return dst;
}

const ushort TLS_VER_12 = 0x0303;

fn void tls_record(char* out, long* olen, char ct, char* payload, long plen)
{
    out[0] = ct;
    out[1] = (char)(TLS_VER_12 >> 8);
    out[2] = (char)(TLS_VER_12 & 0xFF);
    out[3] = (char)((plen >> 8) & 0xFF);
    out[4] = (char)(plen & 0xFF);
    for (long i = 0; i < plen; i++) out[5 + i] = payload[i];
    *olen = 5 + plen;
}

fn long tls_clienthello(char* out, char* random32)
{
    char[300] body;
    long b = 0;
    body[b++] = (char)(TLS_VER_12 >> 8);
    body[b++] = (char)(TLS_VER_12 & 0xFF);
    for (int i = 0; i < 32; i++) body[b++] = random32[i];
    body[b++] = 0;
    body[b++] = 0x00; body[b++] = 0x02;
    body[b++] = 0xC0; body[b++] = 0x2F;
    body[b++] = 0x01; body[b++] = 0x00;
    // ---- extensions so OpenSSL can do ECDHE ----
    // 1. supported_groups (10): P-256(0x0017), P-384(0x0018)
    long extstart = b;
    // we must know the total extension length; write a placeholder then patch it
    body[b++] = 0x00; body[b++] = 0x00;
    // supported_groups
    body[b++] = 0x00; body[b++] = 0x0a;   // type
    body[b++] = 0x00; body[b++] = 0x06;   // len = 6
    body[b++] = 0x00; body[b++] = 0x04;   // vector len
    body[b++] = 0x00; body[b++] = 0x17;   // P-256
    body[b++] = 0x00; body[b++] = 0x18;   // P-384
    // ec_point_formats (11)
    body[b++] = 0x00; body[b++] = 0x0b;
    body[b++] = 0x00; body[b++] = 0x02;
    body[b++] = 0x01; body[b++] = 0x00;   // uncompressed
    // signature_algorithms (13): rsa_pkcs1_sha256(0x0401), rsa_pkcs1_sha384(0x0501)
    body[b++] = 0x00; body[b++] = 0x0d;
    body[b++] = 0x00; body[b++] = 0x06;
    body[b++] = 0x00; body[b++] = 0x04;
    body[b++] = 0x04; body[b++] = 0x01;
    body[b++] = 0x05; body[b++] = 0x01;
    long extlen = b - (extstart + 2);
    body[extstart] = (char)((extlen >> 8) & 0xFF);
    body[extstart + 1] = (char)(extlen & 0xFF);
    // ---- handshake header ----
    char[304] hs;
    hs[0] = 1;
    hs[1] = (char)(b >> 16);
    hs[2] = (char)((b >> 8) & 0xFF);
    hs[3] = (char)(b & 0xFF);
    for (long i = 0; i < b; i++) hs[4 + i] = body[i];
    char[320] rec;
    long olen = 0;
    tls_record(&rec[0], &olen, 22, &hs[0], 4 + b);
    for (long i = 0; i < olen; i++) out[i] = rec[i];
    return olen;
}

fn int xk_host_main(int argc, char** argv) @export("xk_host_main")
{
    (void)argc; (void)argv;
    char[32] random;
    for (int i = 0; i < 32; i++) random[i] = (char)(0x41 + (i % 26));  // fixed, deterministic
    char[320] out;
    long n;
    n = tls_clienthello(&out[0], &random[0]);
    xwrite(1, &out[0], n);
    return 0;
}