module xk;

// ============================================================================
// xenOS from-scratch SHA-256 (FIPS 180-4) + HMAC-SHA256 (RFC 2104).
// Written by hand for the TLS stack; no borrowed code. Provides a streaming
// context (for accumulating the TLS handshake transcript) plus one-shot and
// HMAC helpers. Verified against OpenSSL test vectors (tools/sha256_test.c3).
// ============================================================================

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

struct Sha256Ctx
{
    uint[8] h;
    ulong total;        // total bytes fed
    char[64] buf;
    uint nbuf;          // bytes buffered
}

fn uint sha_rotr(uint x, uint n)
{
    return (x >> n) | (x << (32 - n));
}

// Hash one 64-byte block (big-endian message words) into context state h.
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

fn void sha256_init(Sha256Ctx* s)
{
    s.h[0]=0x6a09e667; s.h[1]=0xbb67ae85; s.h[2]=0x3c6ef372; s.h[3]=0xa54ff53a;
    s.h[4]=0x510e527f; s.h[5]=0x9b05688c; s.h[6]=0x1f83d9ab; s.h[7]=0x5be0cd19;
    s.total = 0;
    s.nbuf = 0;
}

fn void sha256_update(Sha256Ctx* s, char* data, uint len)
{
    s.total += (ulong)len;
    // if we already hold a partial block, top it up first
    if (s.nbuf > 0)
    {
        uint room = 64 - s.nbuf;
        uint take = len < room ? len : room;
        for (uint i = 0; i < take; i++) s.buf[s.nbuf + i] = data[i];
        s.nbuf += take;
        data += take;       // pointer arithmetic on char*
        len -= take;
        if (s.nbuf == 64)
        {
            sha256_block(&s.h[0], &s.buf[0]);
            s.nbuf = 0;
        }
    }
    // process whole blocks from the (remaining) input directly
    while (len >= 64)
    {
        sha256_block(&s.h[0], data);
        data += 64;
        len -= 64;
    }
    // buffer the remainder
    for (uint i = 0; i < len; i++) s.buf[i] = data[i];
    s.nbuf = len;
}

fn void sha256_final(Sha256Ctx* s, char* out)
{
    // append 0x80 then zeros, then 8-byte big-endian bit length; two-block if
    // the padding overflows the current block.
    uint rem = s.nbuf;
    char[64] pad;
    for (int i = 0; i < 64; i++) pad[i] = (char)0;
    for (uint i = 0; i < rem; i++) pad[i] = s.buf[i];
    pad[rem] = (char)0x80;

    char[8] lenbe;
    ulong bits = s.total * 8;
    for (int i = 0; i < 8; i++) lenbe[i] = (char)((bits >> (56 - i * 8)) & 0xFF);

    if (rem < 56)
    {
        for (int i = 0; i < 8; i++) pad[56 + i] = lenbe[i];
        sha256_block(&s.h[0], &pad[0]);
    }
    else
    {
        sha256_block(&s.h[0], &pad[0]);
        char[64] pad2;
        for (int i = 0; i < 64; i++) pad2[i] = (char)0;
        for (int i = 0; i < 8; i++) pad2[56 + i] = lenbe[i];
        sha256_block(&s.h[0], &pad2[0]);
    }
    for (int i = 0; i < 8; i++)
    {
        out[i * 4]     = (char)(s.h[i] >> 24);
        out[i * 4 + 1] = (char)(s.h[i] >> 16);
        out[i * 4 + 2] = (char)(s.h[i] >> 8);
        out[i * 4 + 3] = (char)(s.h[i] & 0xFF);
    }
}

// One-shot SHA-256 of a contiguous buffer.
fn void sha256(char* data, uint len, char* out)
{
    Sha256Ctx s;
    sha256_init(&s);
    sha256_update(&s, data, len);
    sha256_final(&s, out);
}

// HMAC-SHA256 (RFC 2104). Key may be up to 2304 bytes (sha256(key) if >64).
fn void hmac_sha256(char* key, uint keylen, char* msg, uint msglen, char* out)
{
    char[64] k;
    if (keylen > 64)
    {
        sha256(key, keylen, &k[0]);
        for (int i = 32; i < 64; i++) k[i] = (char)0;
    }
    else
    {
        for (uint i = 0; i < keylen; i++) k[i] = key[i];
        for (uint i = keylen; i < 64; i++) k[i] = (char)0;
    }

    char[64] ipad;
    char[64] opad;
    for (int i = 0; i < 64; i++)
    {
        ipad[i] = (char)(k[i] ^ 0x36);
        opad[i] = (char)(k[i] ^ 0x5c);
    }

    // inner = sha256(ipad || msg)
    Sha256Ctx s;
    sha256_init(&s);
    sha256_update(&s, &ipad[0], 64);
    sha256_update(&s, msg, msglen);
    char[32] inner;
    sha256_final(&s, &inner[0]);

    // outer = sha256(opad || inner)
    sha256_init(&s);
    sha256_update(&s, &opad[0], 64);
    sha256_update(&s, &inner[0], 32);
    sha256_final(&s, out);
}

// ---- boot-time self-tests (clean serial region before the demo tasks) ----
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
    char* ehex = (char*)"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    bool ok = true;
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
        if (d[i] != (char)((hi << 4) | lo)) ok = false;
    }
    xk_puts("[sha256] 'abc' = ");
    for (int i = 0; i < 32; i++) xk_put_hex_byte(d[i]);
    xk_puts(ok ? "  PASS\r\n" : "  FAIL\r\n");
}

// verify a 32-byte digest against its lowercase-hex encoding
fn bool hex32_matches(char* digest, char* hex)
{
    for (int i = 0; i < 32; i++)
    {
        uint hi = 0;
        uint lo = 0;
        char c = hex[i * 2];
        if (c >= '0' && c <= '9') { hi = (uint)(c - '0'); }
        else { hi = (uint)(10 + (c - 'a')); }
        c = hex[i * 2 + 1];
        if (c >= '0' && c <= '9') { lo = (uint)(c - '0'); }
        else { lo = (uint)(10 + (c - 'a')); }
        if (digest[i] != (char)((hi << 4) | lo)) return false;
    }
    return true;
}

fn void hmac_selftest()
{
    // RFC 4231 test cases 1 and 2
    char[20] key;
    for (int i = 0; i < 20; i++) key[i] = (char)0x0b;
    char[32] mac1;
    char[32] mac2;
    hmac_sha256(&key[0], 20, (char*)"Hi There", 8, &mac1[0]);
    hmac_sha256((char*)"Jefe", 4, (char*)"what do ya want for nothing?", 28, &mac2[0]);
    bool ok1 = hex32_matches(&mac1[0], (char*)"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
    bool ok2 = hex32_matches(&mac2[0], (char*)"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    xk_puts("[hmac] rfc4231#1 = ");
    for (int i = 0; i < 32; i++) xk_put_hex_byte(mac1[i]);
    xk_puts(ok1 ? "  PASS\r\n" : "  FAIL\r\n");
    xk_puts("[hmac] rfc4231#2 = ");
    for (int i = 0; i < 32; i++) xk_put_hex_byte(mac2[i]);
    xk_puts(ok2 ? "  PASS\r\n" : "  FAIL\r\n");
}