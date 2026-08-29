module sha256_test;
// ============================================================================
// Host self-test for the from-scratch SHA-256 used in the xenOS TLS stack.
// This file is a byte-for-byte copy of kernel/src/xk_sha256.c3's algorithm,
// compiled as a freestanding host tool and run against known FIPS vectors and
// OpenSSL (openssl dgst -sha256) to PROVE correctness before in-kernel use.
// ============================================================================

extern fn long lx_syscall(long n, long a, long b, long c, long d);
fn long xwrite(long fd, char* b, long n) { return lx_syscall(1, fd, (long)b, n, 0); }

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

uint[64] sha256_k =
{
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

fn uint sha_rotr(uint x, uint n) { return (x >> n) | (x << (32 - n)); }

fn void sha256_block(uint* h, char* block)
{
    uint[64] w;
    for (int i = 0; i < 16; i++)
    {
        w[i] = ((uint)((char)block[i * 4]) << 24) | ((uint)((char)block[i * 4 + 1]) << 16) |
               ((uint)((char)block[i * 4 + 2]) << 8) | (uint)((char)block[i * 4 + 3]);
    }
    for (int i = 16; i < 64; i++)
    {
        uint s0 = sha_rotr(w[i - 15], 7) ^ sha_rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint s1 = sha_rotr(w[i - 2], 17) ^ sha_rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint a = h[0];
    uint b = h[1];
    uint c = h[2];
    uint dd = h[3];
    uint e = h[4];
    uint f = h[5];
    uint g = h[6];
    uint hh = h[7];
    for (int i = 0; i < 64; i++)
    {
        uint sum1 = sha_rotr(e, 6) ^ sha_rotr(e, 11) ^ sha_rotr(e, 25);
        uint ch = (e & f) ^ ((~e) & g);
        uint t1 = hh + sum1 + ch + sha256_k[i] + w[i];
        uint sum0 = sha_rotr(a, 2) ^ sha_rotr(a, 13) ^ sha_rotr(a, 22);
        uint maj = (a & b) ^ (a & c) ^ (b & c);
        uint t2 = sum0 + maj;
        hh = g; g = f; f = e; e = dd + t1; dd = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += dd;
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

fn void sha256(char* data, uint len, char* out)
{
    uint[8] h;
    h[0]=0x6a09e667; h[1]=0xbb67ae85; h[2]=0x3c6ef372; h[3]=0xa54ff53a;
    h[4]=0x510e527f; h[5]=0x9b05688c; h[6]=0x1f83d9ab; h[7]=0x5be0cd19;
    uint full = len / 64;
    for (uint i = 0; i < full; i++) sha256_block(&h[0], &data[i * 64]);
    char[8] lenbe;
    ulong bits = (ulong)len * 8;
    for (int i = 0; i < 8; i++) lenbe[i] = (char)((bits >> (56 - i * 8)) & 0xFF);
    uint rem = len & 63;
    char[64] pad;
    memset(&pad[0], 0, 64);
    for (uint i = 0; i < rem; i++) pad[i] = data[full * 64 + i];
    pad[rem] = (char)0x80;
    if (rem < 56)
    {
        for (int i = 0; i < 8; i++) pad[56 + i] = lenbe[i];
        sha256_block(&h[0], &pad[0]);
    }
    else
    {
        sha256_block(&h[0], &pad[0]);
        char[64] pad2;
        memset(&pad2[0], 0, 64);
        for (int i = 0; i < 8; i++) pad2[56 + i] = lenbe[i];
        sha256_block(&h[0], &pad2[0]);
    }
    for (int i = 0; i < 8; i++)
    {
        out[i * 4]     = (char)(h[i] >> 24);
        out[i * 4 + 1] = (char)(h[i] >> 16);
        out[i * 4 + 2] = (char)(h[i] >> 8);
        out[i * 4 + 3] = (char)(h[i] & 0xFF);
    }
}

fn void print_hex(char* d)
{
    for (int i = 0; i < 32; i++)
    {
        char hi = (char)("0123456789abcdef"[(int)((d[i] >> 4) & 0xF)]);
        char lo = (char)("0123456789abcdef"[(int)(d[i] & 0xF)]);
        xwrite(1, &hi, 1); xwrite(1, &lo, 1);
    }
}

fn void run_case(char* label, char* data, uint len)
{
    char[32] d;
    sha256(data, len, &d[0]);
    char[20] lbl;
    for (int i = 0; label[i] != 0 && i < 19; i++) lbl[i] = label[i];
    xwrite(1, &lbl[0], 8);
    xwrite(1, (char*)" = ", 3);
    print_hex(&d[0]);
    xwrite(1, (char*)"\n", 1);
}

fn int xk_host_main(int argc, char** argv) @export("xk_host_main")
{
    (void)argc; (void)argv;
    xwrite(1, (char*)"SHA-256 self-test (compare with openssl dgst -sha256):\n", 54);
    run_case((char*)"empty   ", (char*)"", 0);
    run_case((char*)"abc     ", (char*)"abc", 3);
    run_case((char*)"multi   ", (char*)"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56);
    // long input > 64 bytes to exercise the multi-block padding path
    char[100] big;
    for (int i = 0; i < 100; i++) big[i] = (char)('a');
    run_case((char*)"exactly1", (char*)"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu", 112);
    run_case((char*)"100a    ", &big[0], 100);
    // rem>=56 (two-block padding) : 59 bytes of 'b'
    char[59] b59;
    for (int i = 0; i < 59; i++) b59[i] = (char)('b');
    run_case((char*)"59b     ", &b59[0], 59);
    return 0;
}