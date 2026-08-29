module xk;

// ============================================================================
// xenOS from-scratch SHA-256 (FIPS 180-4). Written by hand for the TLS stack;
// no borrowed code. Iterative over caller-managed input (used by the TLS
// stack / shell `sha256` command and verified against OpenSSL test vectors).
// ============================================================================

// 64 round constants (first 32 bits of the fractional parts of the cube roots
// of the first 64 primes). Runtime-read (mutable) because we index it.
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

fn uint sha_rotr(uint x, uint n)
{
    return (x >> n) | (x << (32 - n));
}

// Hash one 64-byte block (big-endian message words). h is 8 working state words.
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

// Boot-time self-test: hash "abc" and compare against the printed digest.
// Runs before the demo tasks so the serial region is clean.
fn void xk_put_hex_byte(char b)
{
    char* he = (char*)"0123456789abcdef";
    xk_putc(he[((int)b >> 4) & 0xF]);
    xk_putc(he[(int)b & 0xF]);
}

fn void sha256_selftest()
{
    char[32] d;
    sha256((char*)"abc", 3, &d[0]);
    char[32] expect;
    char* ehex = (char*)"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    for (int i = 0; i < 32; i++)
    {
        uint hi = 0;
        uint lo = 0;

        char c = ehex[i * 2];
        if (c >= '0' && c <= '9') { hi = (uint)(c - '0'); }
        else { hi = (uint)(10 + (c - 'a')); }
        c = ehex[i * 2 + 1];
        if (c >= '0' && c <= '9') { lo = (uint)(c - '0'); }
        else { lo = (uint)(10 + (c - 'a')); }
        expect[i] = (char)((hi << 4) | lo);
    }
    bool ok = true;
    for (int i = 0; i < 32; i++) { if (d[i] != expect[i]) { ok = false; break; } }
    xk_puts("[sha256] 'abc' = ");
    for (int i = 0; i < 32; i++) xk_put_hex_byte(d[i]);
    xk_puts(ok ? "  PASS\r\n" : "  FAIL\r\n");
}

fn void sha256(char* data, uint len, char* out)
{
    uint[8] h;
    h[0]=0x6a09e667; h[1]=0xbb67ae85; h[2]=0x3c6ef372; h[3]=0xa54ff53a;
    h[4]=0x510e527f; h[5]=0x9b05688c; h[6]=0x1f83d9ab; h[7]=0x5be0cd19;

    // all full 64-byte blocks
    uint full = len / 64;
    for (uint i = 0; i < full; i++)
    {
        sha256_block(&h[0], &data[i * 64]);
    }

    // 8-byte big-endian message length (in bits)
    char[8] lenbe;
    ulong bits = (ulong)len * 8;
    for (int i = 0; i < 8; i++) lenbe[i] = (char)((bits >> (56 - i * 8)) & 0xFF);

    uint rem = len & 63;
    char[64] pad;
    for (int i = 0; i < 64; i++) pad[i] = (char)0;
    for (uint i = 0; i < rem; i++) pad[i] = data[full * 64 + i];
    pad[rem] = (char)0x80;

    if (rem < 56)
    {
        for (int i = 0; i < 8; i++) pad[56 + i] = lenbe[i];
        sha256_block(&h[0], &pad[0]);
    }
    else
    {
        // can't fit the length in this block: emit block1 (padding only), then a
        // zero block carrying the length at the end.
        sha256_block(&h[0], &pad[0]);
        char[64] pad2;
        for (int i = 0; i < 64; i++) pad2[i] = (char)0;
        for (int i = 0; i < 8; i++) pad2[56 + i] = lenbe[i];
        sha256_block(&h[0], &pad2[0]);
    }

    // output big-endian
    for (int i = 0; i < 8; i++)
    {
        out[i * 4]     = (char)(h[i] >> 24);
        out[i * 4 + 1] = (char)(h[i] >> 16);
        out[i * 4 + 2] = (char)(h[i] >> 8);
        out[i * 4 + 3] = (char)(h[i] & 0xFF);
    }
}