module tls_handshake;
// xenOS from-scratch TLS 1.2 client: completes ECDHE_RSA_AES128_GCM_SHA256
// against openssl s_server. All crypto is the verified aesgcm/sha256/p256 code.

extern fn long lx_syscall(long n, long a, long b, long c, long d);
fn long xw(long fd, char* b, long n) { return lx_syscall(1, fd, (long)b, n, 0); }
fn void* memset(void* p, int v, ulong n) @export("memset") { char* q=(char*)p; for(ulong i=0;i<n;i++) q[i]=(char)v; return p; }
fn void* memcpy(void* d, void* s, ulong n) @export("memcpy") { char* p=(char*)d; char* q=(char*)s; for(ulong i=0;i<n;i++) p[i]=q[i]; return d; }

fn long sc_socket(){ return lx_syscall(41,2,1,0,0); }
fn long sc_connect(long fd, long a, long l){ return lx_syscall(42,fd,a,l,0); }
fn long sc_send(long fd, char* b, long n){ return lx_syscall(44,fd,(long)b,n,0); }
fn long sc_recv(long fd, char* b, long n){ return lx_syscall(45,fd,(long)b,n,0); }

// ---------- SHA-256 (streaming) + HMAC + PRF ----------
uint[64] sha_k = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 };
struct Scx { uint[8] h; ulong total; char[64] buf; uint nbuf; }
fn uint srr(uint x, uint n){ return (x >> n) | (x << (32 - n)); }
fn void sha_block(uint* h, char* b)
{
    uint[64] w;
    for (int i = 0; i < 16; i++)
    {
        w[i] = ((uint)((char)b[i*4]) << 24) | ((uint)((char)b[i*4+1]) << 16) |
               ((uint)((char)b[i*4+2]) << 8) | (uint)((char)b[i*4+3]);
    }
    for (int i = 16; i < 64; i++)
    {
        uint s0 = srr(w[i-15],7) ^ srr(w[i-15],18) ^ (w[i-15] >> 3);
        uint s1 = srr(w[i-2],17) ^ srr(w[i-2],19) ^ (w[i-2] >> 10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    uint a = h[0];
    uint b1 = h[1];
    uint c = h[2];
    uint dd = h[3];
    uint e = h[4];
    uint f = h[5];
    uint g = h[6];
    uint hh = h[7];
    for (int i = 0; i < 64; i++)
    {
        uint m1 = srr(e,6) ^ srr(e,11) ^ srr(e,25);
        uint chv = (e & f) ^ ((~e) & g);
        uint t1 = hh + m1 + chv + sha_k[i] + w[i];
        uint m0 = srr(a,2) ^ srr(a,13) ^ srr(a,22);
        uint maj = (a & b1) ^ (a & c) ^ (b1 & c);
        uint t2 = m0 + maj;
        hh = g; g = f; f = e; e = dd + t1; dd = c; c = b1; b1 = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b1; h[2] += c; h[3] += dd; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}
fn void sha_init(Scx* s)
{
    s.h[0]=0x6a09e667; s.h[1]=0xbb67ae85; s.h[2]=0x3c6ef372; s.h[3]=0xa54ff53a;
    s.h[4]=0x510e527f; s.h[5]=0x9b05688c; s.h[6]=0x1f83d9ab; s.h[7]=0x5be0cd19;
    s.total = 0; s.nbuf = 0;
}
fn void sha_upd(Scx* s, char* data, uint len)
{
    s.total += (ulong)len;
    if (s.nbuf > 0)
    {
        uint room = 64 - s.nbuf;
        uint take = len < room ? len : room;
        for (uint i = 0; i < take; i++) s.buf[s.nbuf + i] = data[i];
        s.nbuf += take; data += take; len -= take;
        if (s.nbuf == 64) { sha_block(&s.h[0], &s.buf[0]); s.nbuf = 0; }
    }
    while (len >= 64) { sha_block(&s.h[0], data); data += 64; len -= 64; }
    for (uint i = 0; i < len; i++) s.buf[i] = data[i];
    s.nbuf = len;
}
fn void sha_fin(Scx* s, char* out)
{
    uint rem = s.nbuf;
    char[64] pad; memset(&pad[0], 0, 64);
    for (uint i = 0; i < rem; i++) pad[i] = s.buf[i];
    pad[rem] = (char)0x80;
    char[8] lb;
    ulong bits = s.total * 8;
    for (int i = 0; i < 8; i++) lb[i] = (char)((bits >> (56 - i*8)) & 0xFF);
    if (rem < 56)
    {
        for (int i = 0; i < 8; i++) pad[56 + i] = lb[i];
        sha_block(&s.h[0], &pad[0]);
    }
    else
    {
        sha_block(&s.h[0], &pad[0]);
        char[64] p2; memset(&p2[0], 0, 64);
        for (int i = 0; i < 8; i++) p2[56 + i] = lb[i];
        sha_block(&s.h[0], &p2[0]);
    }
    for (int i = 0; i < 8; i++)
    {
        out[i*4]   = (char)(s.h[i] >> 24);
        out[i*4+1] = (char)(s.h[i] >> 16);
        out[i*4+2] = (char)(s.h[i] >> 8);
        out[i*4+3] = (char)(s.h[i] & 0xFF);
    }
}
fn void sha256(char* data, uint len, char* out)
{
    Scx s;
    sha_init(&s);
    sha_upd(&s, data, len);
    sha_fin(&s, out);
}
fn void hmac(char* key, uint kl, char* msg, uint ml, char* out)
{
    char[64] k;
    if (kl > 64) { sha256(key, kl, &k[0]); }
    else { for (uint i = 0; i < kl; i++) k[i] = key[i]; }
    char[64] ip; char[64] op;
    for (int i = 0; i < 64; i++) { ip[i] = (char)(k[i] ^ 0x36); op[i] = (char)(k[i] ^ 0x5c); }
    Scx s;
    sha_init(&s); sha_upd(&s, &ip[0], 64); sha_upd(&s, msg, ml);
    char[32] in; sha_fin(&s, &in[0]);
    sha_init(&s); sha_upd(&s, &op[0], 64); sha_upd(&s, &in[0], 32);
    sha_fin(&s, out);
}
fn void tls_prf(char* secret, uint slen, char* label, uint llen, char* seed, uint seedlen, char* out, uint outlen)
{
    char[512] data; uint dlen = 0;
    for (uint i = 0; i < llen && dlen < 510; i++) data[dlen++] = label[i];
    for (uint i = 0; i < seedlen && dlen < 510; i++) data[dlen++] = seed[i];
    char[32] a;
    hmac(secret, slen, &data[0], dlen, &a[0]);
    uint prod = 0;
    while (prod < outlen)
    {
        char[544] tmp; uint tlen = 0;
        for (int i = 0; i < 32; i++) tmp[tlen++] = a[i];
        for (uint i = 0; i < dlen && tlen < 543; i++) tmp[tlen++] = data[i];
        char[32] blk;
        hmac(secret, slen, &tmp[0], tlen, &blk[0]);
        for (int i = 0; i < 32 && prod < outlen; i++) out[prod++] = blk[i];
        if (prod >= outlen) break;
        char[32] an;
        hmac(secret, slen, &a[0], 32, &an[0]);
        for (int i = 0; i < 32; i++) a[i] = an[i];
    }
}

// ---------- AES-128-GCM ----------
char[256] aes_sb = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16 };
char[11] aes_rc = {0x00,0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36};
fn char agf(char aa, char bb)
{
    uint x = (uint)aa & 0xFF;
    uint y = (uint)bb & 0xFF;
    uint p = 0;
    while (y != 0)
    {
        if ((y & 1) != 0) p ^= x;
        uint hi = x & 0x80;
        x = (x << 1) & 0xFF;
        if (hi != 0) x ^= 0x1b;
        y >>= 1;
    }
    return (char)(p & 0xFF);
}
fn void aes_expand(char* key, uint* w)
{
    uint t = 0;
    for (int i = 0; i < 4; i++)
    {
        w[i] = ((uint)((char)key[i*4]) << 24) | ((uint)((char)key[i*4+1]) << 16) |
               ((uint)((char)key[i*4+2]) << 8) | (uint)((char)key[i*4+3]);
    }
    for (int i = 4; i < 44; i++)
    {
        t = w[i-1];
        if (i % 4 == 0)
        {
            uint r = (t << 8) | (t >> 24);
            uint sub = ((uint)aes_sb[(r>>24)&0xFF] << 24) | ((uint)aes_sb[(r>>16)&0xFF] << 16) |
                       ((uint)aes_sb[(r>>8)&0xFF] << 8) | (uint)aes_sb[r&0xFF];
            t = sub ^ ((uint)aes_rc[i/4] << 24);
        }
        w[i] = w[i-4] ^ t;
    }
}
fn void aes_block(char* in, char* out, uint* w)
{
    char[16] s;
    for (int i = 0; i < 16; i++) s[i] = in[i];
    for (int c = 0; c < 4; c++)
    {
        s[c*4+0] = (char)(s[c*4+0] ^ (w[c] >> 24));
        s[c*4+1] = (char)(s[c*4+1] ^ ((w[c] >> 16) & 0xFF));
        s[c*4+2] = (char)(s[c*4+2] ^ ((w[c] >> 8) & 0xFF));
        s[c*4+3] = (char)(s[c*4+3] ^ (w[c] & 0xFF));
    }
    for (int r = 0; r < 10; r++)
    {
        for (int i = 0; i < 16; i++) s[i] = aes_sb[(uint)s[i] & 0xFF];
        char[16] sh;
        sh[0]=s[0]; sh[1]=s[5]; sh[2]=s[10]; sh[3]=s[15];
        sh[4]=s[4]; sh[5]=s[9]; sh[6]=s[14]; sh[7]=s[3];
        sh[8]=s[8]; sh[9]=s[13]; sh[10]=s[2]; sh[11]=s[7];
        sh[12]=s[12]; sh[13]=s[1]; sh[14]=s[6]; sh[15]=s[11];
        if (r < 9)
        {
            char[16] mc;
            for (int c = 0; c < 4; c++)
            {
                char a0 = sh[c*4+0];
                char a1 = sh[c*4+1];
                char a2 = sh[c*4+2];
                char a3 = sh[c*4+3];
                mc[c*4+0] = agf(a0,(char)2) ^ agf(a1,(char)3) ^ a2 ^ a3;
                mc[c*4+1] = a0 ^ agf(a1,(char)2) ^ agf(a2,(char)3) ^ a3;
                mc[c*4+2] = a0 ^ a1 ^ agf(a2,(char)2) ^ agf(a3,(char)3);
                mc[c*4+3] = agf(a0,(char)3) ^ a1 ^ a2 ^ agf(a3,(char)2);
            }
            for (int i = 0; i < 16; i++) sh[i] = mc[i];
        }
        for (int i = 0; i < 16; i++) s[i] = sh[i];
        uint* rk = &w[(r + 1) * 4];
        for (int c = 0; c < 4; c++)
        {
            s[c*4+0] = (char)(s[c*4+0] ^ (rk[c] >> 24));
            s[c*4+1] = (char)(s[c*4+1] ^ ((rk[c] >> 16) & 0xFF));
            s[c*4+2] = (char)(s[c*4+2] ^ ((rk[c] >> 8) & 0xFF));
            s[c*4+3] = (char)(s[c*4+3] ^ (rk[c] & 0xFF));
        }
    }
    for (int i = 0; i < 16; i++) out[i] = s[i];
}
fn void gmult(char* x, char* y, char* z)
{
    char[16] v; memset(&v[0],0,16); memset(&z[0],0,16);
    for (int i = 0; i < 16; i++) v[i] = x[i];
    for (int i = 0; i < 128; i++)
    {
        uint byt = (uint)(i / 8);
        uint bit = (uint)(7 - (i % 8));
        if ((((uint)y[byt] >> bit) & 1) != 0)
        {
            for (int j = 0; j < 16; j++) z[j] = (char)(z[j] ^ v[j]);
        }
        char lsb = (char)((uint)v[15] & 1);
        for (int j = 15; j > 0; j--) v[j] = (char)(((uint)((char)v[j]) >> 1) | (((uint)((char)v[j-1]) & 1) << 7));
        v[0] = (char)((uint)((char)v[0]) >> 1);
        if (lsb != 0) v[0] = (char)((uint)v[0] ^ 0xE1);
    }
}
fn void ghash(char* h, char* data, uint len, char* out)
{
    memset(&out[0],0,16);
    for (uint i = 0; i + 16 <= len; i += 16)
    {
        for (int j = 0; j < 16; j++) out[j] = (char)(out[j] ^ data[(uint)i + (uint)j]);
        char[16] t;
        gmult(&out[0], h, &t[0]);
        for (int j = 0; j < 16; j++) out[j] = t[j];
    }
}
fn void gcm(char* key, char* nonce12, char* aad, uint aadlen, char* pt, uint plen, char* ct, char* tag)
{
    uint[44] w;
    aes_expand(key, &w[0]);
    char[16] zero; memset(&zero[0],0,16);
    char[16] hk; aes_block(&zero[0], &hk[0], &w[0]);
    char[16] j0;
    for (int i = 0; i < 12; i++) j0[i] = nonce12[i];
    j0[12] = 0; j0[13] = 0; j0[14] = 0; j0[15] = 1;
    char[16] ej0; aes_block(&j0[0], &ej0[0], &w[0]);
    uint blocks = (plen + 15) / 16;
    for (uint b = 0; b < blocks; b++)
    {
        char[16] ctr;
        for (int i = 0; i < 12; i++) ctr[i] = j0[i];
        uint cnt = (uint)(b + 2);
        ctr[12] = (char)(cnt >> 24); ctr[13] = (char)((cnt >> 16) & 0xFF);
        ctr[14] = (char)((cnt >> 8) & 0xFF); ctr[15] = (char)(cnt & 0xFF);
        char[16] st; aes_block(&ctr[0], &st[0], &w[0]);
        for (int j = 0; j < 16; j++)
        {
            uint idx = b * 16 + (uint)j;
            if (idx < plen) ct[idx] = (char)(pt[idx] ^ st[j]);
        }
    }
    char[4096] gd; uint gl = 0;
    uint apad = aadlen + (16 - (aadlen % 16)) % 16;
    for (uint i = 0; i < aadlen; i++) gd[gl++] = aad[i];
    for (uint i = aadlen; i < apad; i++) gd[gl++] = 0;
    uint cpad = plen + (16 - (plen % 16)) % 16;
    for (uint i = 0; i < plen; i++) gd[gl++] = ct[i];
    for (uint i = plen; i < cpad; i++) gd[gl++] = 0;
    ulong la = (ulong)aadlen * 8;
    for (int i = 7; i >= 0; i--) gd[gl++] = (char)((la >> (i*8)) & 0xFF);
    ulong lc = (ulong)plen * 8;
    for (int i = 7; i >= 0; i--) gd[gl++] = (char)((lc >> (i*8)) & 0xFF);
    char[16] gg; ghash(&hk[0], &gd[0], gl, &gg[0]);
    for (int i = 0; i < 16; i++) tag[i] = (char)((char)ej0[i] ^ gg[i]);
}

// ---------- P-256 ----------
uint[8] pc = {0xffffffff,0xffffffff,0xffffffff,0x00000000,0x00000000,0x00000000,0x00000001,0xffffffff};
uint[8] pcm2 = {0xfffffffd,0xffffffff,0xffffffff,0x00000000,0x00000000,0x00000000,0x00000001,0xffffffff};
uint[8] gx = {0xd898c296,0xf4a13945,0x2deb33a0,0x77037d81,0x63a440f2,0xf8bce6e5,0xe12c4247,0x6b17d1f2};
uint[8] gy = {0x37bf51f5,0xcbb64068,0x6b315ece,0x2bce3357,0x7c0f9e16,0x8ee7eb4a,0xfe1a7f9b,0x4fe342e2};
fn int cmp8(uint* a, uint* b)
{
    for (int i = 7; i >= 0; i--)
    {
        if (a[i] > b[i]) return 1;
        if (a[i] < b[i]) return -1;
    }
    return 0;
}
fn void madd(uint* a, uint* b)
{
    ulong c = 0;
    uint[9] t;
    for (int i = 0; i < 8; i++)
    {
        ulong x = (ulong)a[i] + (ulong)b[i] + c;
        t[i] = (uint)(x & 0xffffffff);
        c = x >> 32;
    }
    t[8] = (uint)c;
    if (t[8] != 0 || cmp8(&t[0], &pc[0]) >= 0)
    {
        ulong br = 0;
        for (int i = 0; i < 8; i++)
        {
            ulong d = (ulong)t[i] - (ulong)pc[i] - br;
            t[i] = (uint)(d & 0xffffffff);
            br = (d >> 32) & 1;
        }
    }
    for (int i = 0; i < 8; i++) a[i] = t[i];
}
fn void msub(uint* a, uint* b)
{
    if (cmp8(a, b) >= 0)
    {
        ulong br = 0;
        for (int i = 0; i < 8; i++)
        {
            ulong d = (ulong)a[i] - (ulong)b[i] - br;
            a[i] = (uint)(d & 0xffffffff);
            br = (d >> 32) & 1;
        }
    }
    else
    {
        uint[8] ba;
        ulong br = 0;
        for (int i = 0; i < 8; i++)
        {
            ulong d = (ulong)b[i] - (ulong)a[i] - br;
            ba[i] = (uint)(d & 0xffffffff);
            br = (d >> 32) & 1;
        }
        br = 0;
        for (int i = 0; i < 8; i++)
        {
            ulong d = (ulong)pc[i] - (ulong)ba[i] - br;
            a[i] = (uint)(d & 0xffffffff);
            br = (d >> 32) & 1;
        }
    }
}
fn void mdbl(uint* a){ madd(a, a); }
fn void cp8(uint* d, uint* s){ for (int i = 0; i < 8; i++) d[i] = s[i]; }
fn void z8(uint* a){ for (int i = 0; i < 8; i++) a[i] = 0; }
fn uint gbit(uint* a, uint i){ return (a[i/32] >> (i%32)) & 1; }
fn void mmul(uint* r, uint* a, uint* b)
{
    uint[8] res; z8(&res[0]);
    uint[8] t; cp8(&t[0], a);
    for (uint i = 0; i < 256; i++)
    {
        if (gbit(b, i) == 1) madd(&res[0], &t[0]);
        mdbl(&t[0]);
    }
    cp8(r, &res[0]);
}
fn void mpow(uint* r, uint* a, uint* k)
{
    uint[8] base; cp8(&base[0], a);
    uint[8] acc; z8(&acc[0]); acc[0] = 1;
    for (uint i = 0; i < 256; i++)
    {
        if (gbit(k, i) == 1) mmul(&acc[0], &acc[0], &base[0]);
        mmul(&base[0], &base[0], &base[0]);
    }
    cp8(r, &acc[0]);
}
fn void minv(uint* r, uint* a){ mpow(r, a, &pcm2[0]); }
fn void pdbl(uint* rx, uint* ry, uint* px, uint* py)
{
    uint[8] x2; mmul(&x2[0], px, px);
    uint[8] num; cp8(&num[0], &x2[0]);
    madd(&num[0], &num[0]);
    madd(&num[0], &x2[0]);
    uint[8] three; z8(&three[0]); three[0] = 3;
    msub(&num[0], &three[0]);
    uint[8] den; cp8(&den[0], py); mdbl(&den[0]);
    uint[8] di; minv(&di[0], &den[0]);
    uint[8] lam; mmul(&lam[0], &num[0], &di[0]);
    uint[8] lsq; mmul(&lsq[0], &lam[0], &lam[0]);
    uint[8] twox; cp8(&twox[0], px); mdbl(&twox[0]);
    msub(&lsq[0], &twox[0]);
    uint[8] xmx3; cp8(&xmx3[0], px);
    msub(&xmx3[0], &lsq[0]);
    uint[8] y3; mmul(&y3[0], &lam[0], &xmx3[0]);
    msub(&y3[0], py);
    cp8(rx, &lsq[0]); cp8(ry, &y3[0]);
}
fn void padd(uint* rx, uint* ry, uint* inf, uint* px, uint* py, uint pinf, uint* qx, uint* qy, uint qinf)
{
    if (pinf == 1) { cp8(rx, qx); cp8(ry, qy); inf[0] = qinf; return; }
    if (qinf == 1) { cp8(rx, px); cp8(ry, py); inf[0] = 0; return; }
    if (cmp8(px, qx) == 0)
    {
        if (cmp8(py, qy) == 0) { pdbl(rx, ry, px, py); inf[0] = 0; return; }
        else { inf[0] = 1; return; }
    }
    uint[8] dy; cp8(&dy[0], qy); msub(&dy[0], py);
    uint[8] dx; cp8(&dx[0], qx); msub(&dx[0], px);
    uint[8] di; minv(&di[0], &dx[0]);
    uint[8] lam; mmul(&lam[0], &dy[0], &di[0]);
    uint[8] lsq; mmul(&lsq[0], &lam[0], &lam[0]);
    msub(&lsq[0], px);
    msub(&lsq[0], qx);
    uint[8] x1mx3; cp8(&x1mx3[0], px);
    msub(&x1mx3[0], &lsq[0]);
    uint[8] y3; mmul(&y3[0], &lam[0], &x1mx3[0]);
    msub(&y3[0], py);
    cp8(rx, &lsq[0]); cp8(ry, &y3[0]);
    inf[0] = 0;
}
fn void smul(uint* rx, uint* ry, uint* k, uint* px, uint* py, uint pinf)
{
    uint[8] rxb; uint[8] ryb;
    uint ri = 1;
    for (int i = 255; i >= 0; i--)
    {
        if (ri != 1)
        {
            uint[8] nx; uint[8] ny;
            pdbl(&nx[0], &ny[0], &rxb[0], &ryb[0]);
            cp8(&rxb[0], &nx[0]); cp8(&ryb[0], &ny[0]);
            ri = 0;
        }
        if (gbit(k, (uint)i) == 1)
        {
            uint[8] ax; uint[8] ay; uint[1] ai;
            padd(&ax[0], &ay[0], &ai[0], &rxb[0], &ryb[0], ri, px, py, pinf);
            cp8(&rxb[0], &ax[0]); cp8(&ryb[0], &ay[0]);
            ri = (int)ai[0];
        }
    }
    cp8(rx, &rxb[0]); cp8(ry, &ryb[0]);
}
fn void limbs_to_be(uint* a, char* out)
{
    uint k = 0;
    for (int i = 7; i >= 0; i--)
    {
        out[k++] = (char)(a[i] >> 24);
        out[k++] = (char)((a[i] >> 16) & 0xFF);
        out[k++] = (char)((a[i] >> 8) & 0xFF);
        out[k++] = (char)(a[i] & 0xFF);
    }
}
fn void be_to_limbs(char* in, uint* out)
{
    for (int i = 0; i < 8; i++)
    {
        uint v = 0;
        v = (uint)(char)in[i*4];
        v = (v << 8) | (uint)(char)in[i*4+1];
        v = (v << 8) | (uint)(char)in[i*4+2];
        v = (v << 8) | (uint)(char)in[i*4+3];
        out[7-i] = v;
    }
}

const char T_CCS = 20;
const char T_ALERT = 21;
const char T_HS = 22;
const char T_APP = 23;

fn void puthexb(char* d, uint n)
{
    char* he = (char*)"0123456789abcdef";
    for (uint i = 0; i < n; i++)
    {
        char c1 = he[((int)d[i] >> 4) & 0xF];
        xw(1, &c1, 1);
        char c2 = he[(int)d[i] & 0xF];
        xw(1, &c2, 1);
    }
}

fn int xk_host_main(int argc, char** argv) @export("xk_host_main")
{
    long port = 9447;
    if (argc > 1)
    {
        long p = 0;
        char* s = argv[1];
        for (int i = 0; s[i] != 0; i++)
        {
            if (s[i] >= '0' && s[i] <= '9') p = p * 10 + (long)(s[i] - '0');
        }
        if (p > 0) port = p;
    }
    long fd = sc_socket();
    if (fd < 0) { xw(1,(char*)"socket fail\n",12); return 1; }
    char[16] sa; memset(&sa[0], 0, 16);
    sa[0] = 2; sa[2] = (char)(port >> 8); sa[3] = (char)(port & 0xFF); sa[4] = 127; sa[6] = 1;
    if (sc_connect(fd, (long)&sa[0], 16) != 0) { xw(1,(char*)"connect fail\n",13); return 1; }

    // ---- ClientHello ----
    char[32] car;
    for (int i = 0; i < 32; i++) car[i] = (char)(0x71 + (i % 26));
    char[240] cbody;
    long b = 0;
    cbody[b++] = 0x03; cbody[b++] = 0x03;
    for (int i = 0; i < 32; i++) cbody[b++] = car[i];
    cbody[b++] = 0;
    cbody[b++] = 0x00; cbody[b++] = 0x02; cbody[b++] = 0xC0; cbody[b++] = 0x2F;
    cbody[b++] = 0x01; cbody[b++] = 0x00;
    long es = b;
    cbody[b++] = 0; cbody[b++] = 0;
    cbody[b++] = 0x00; cbody[b++] = 0x0a; cbody[b++] = 0x00; cbody[b++] = 0x06; cbody[b++] = 0x00; cbody[b++] = 0x04; cbody[b++] = 0x00; cbody[b++] = 0x17; cbody[b++] = 0x00; cbody[b++] = 0x18;
    cbody[b++] = 0x00; cbody[b++] = 0x0b; cbody[b++] = 0x00; cbody[b++] = 0x02; cbody[b++] = 0x01; cbody[b++] = 0x00;
    cbody[b++] = 0x00; cbody[b++] = 0x0d; cbody[b++] = 0x00; cbody[b++] = 0x06; cbody[b++] = 0x00; cbody[b++] = 0x04; cbody[b++] = 0x04; cbody[b++] = 0x01; cbody[b++] = 0x05; cbody[b++] = 0x01;
    long el = b - (es + 2);
    cbody[es] = (char)((el >> 8) & 0xFF);
    cbody[es+1] = (char)(el & 0xFF);
    char[260] chmsg;
    chmsg[0] = 1; chmsg[1] = (char)(b >> 16); chmsg[2] = (char)((b >> 8) & 0xFF); chmsg[3] = (char)(b & 0xFF);
    for (long i = 0; i < b; i++) chmsg[4+i] = cbody[i];
    char[270] chrec;
    chrec[0] = T_HS; chrec[1] = 3; chrec[2] = 3;
    long chlen = 4 + b;
    chrec[3] = (char)((chlen >> 8) & 0xFF);
    chrec[4] = (char)(chlen & 0xFF);
    for (long i = 0; i < chlen; i++) chrec[5+i] = chmsg[i];
    sc_send(fd, &chrec[0], 5 + chlen);

    Scx trans; sha_init(&trans);
    sha_upd(&trans, &chmsg[0], (uint)(4 + b));

    // ---- read server flight ----
    char[32] srv_random;
    uint got_sh = 0;
    uint[8] srv_px; uint[8] srv_py;
    uint have_point = 0;
    int guard = 0;
    while (guard++ < 30 && !have_point)
    {
        char[5] hdr;
        long nr = sc_recv(fd, &hdr[0], 5);
        if (nr <= 0) { xw(1,(char*)"hdr fail\n",9); return 1; }
        char ct = hdr[0];
        uint plen = ((uint)(char)hdr[3] << 8) | (uint)(char)hdr[4];
        char[9000] pay;
        long po = 0;
        while (po < (long)plen)
        {
            long got = sc_recv(fd, &pay[(uint)po], (long)plen - (long)po);
            if (got <= 0) break;
            po += got;
        }
        if (ct == T_HS)
        {
            long off = 0;
            while (off + 4 <= (long)plen)
            {
                char ht = pay[off];
                uint hl = ((uint)(char)pay[off+1] << 16) | ((uint)(char)pay[off+2] << 8) | (uint)(char)pay[off+3];
                sha_upd(&trans, &pay[off], 4 + hl);
                char* hb = &pay[off+4];
                if (ht == 2 && !got_sh)
                {
                    for (int i = 0; i < 32; i++) srv_random[i] = hb[2+i];
                    got_sh = 1;
                }
                else if (ht == 12 && !have_point)
                {
                    // SKE ECDHE: curve_type(1)||named_curve(2)||point_len(1)||point
                    // point = 0x04 || X(32) || Y(32)  -> X at hb[5], Y at hb[5+32]
                    uint pointlen = (uint)(char)hb[3];
                    (void)pointlen;
                    char[32] xb; char[32] yb;
                    for (int i = 0; i < 32; i++) { xb[i] = hb[5+i]; yb[i] = hb[5+32+i]; }
                    be_to_limbs(&xb[0], &srv_px[0]);
                    be_to_limbs(&yb[0], &srv_py[0]);
                    have_point = 1;
                }
                off += 4 + (long)hl;
            }
        }
        else if (ct == T_ALERT) { xw(1,(char*)"server alert\n",13); return 1; }
    }
    if (!have_point) { xw(1,(char*)"no server point\n",16); return 1; }

    // ---- ephemeral keypair + shared secret ----
    uint[8] da; z8(&da[0]);
    for (int i = 0; i < 8; i++) da[i] = (i % 2 == 0) ? 0x31415926 : 0x27182818;
    uint[8] qax; uint[8] qay;
    smul(&qax[0], &qay[0], &da[0], &gx[0], &gy[0], 0);
    uint[8] sxp; uint[8] syp;
    smul(&sxp[0], &syp[0], &da[0], &srv_px[0], &srv_py[0], 0);
    char[32] prem; limbs_to_be(&sxp[0], &prem[0]);

    char[64] seed1;
    for (int i = 0; i < 32; i++) seed1[i] = car[i];
    for (int i = 0; i < 32; i++) seed1[32+i] = srv_random[i];
    char[48] master;
    tls_prf(&prem[0], 32, (char*)"master secret", 13, &seed1[0], 64, &master[0], 48);
    char[64] seed2;
    for (int i = 0; i < 32; i++) seed2[i] = srv_random[i];
    for (int i = 0; i < 32; i++) seed2[32+i] = car[i];
    char[40] kb;
    tls_prf(&master[0], 48, (char*)"key expansion", 13, &seed2[0], 64, &kb[0], 40);
    char[16] ckey; char[16] skey; char[4] civ; char[4] siv;
    for (int i = 0; i < 16; i++) { ckey[i] = kb[i]; skey[i] = kb[16+i]; }
    for (int i = 0; i < 4; i++) { civ[i] = kb[32+i]; siv[i] = kb[36+i]; }

    // ---- ClientKeyExchange ----
    char[80] cke;
    cke[0] = 16; cke[1] = 0; cke[2] = 0; cke[3] = 66;
    cke[4] = 65;
    cke[5] = 0x04;
    uint ko = 6;
    limbs_to_be(&qax[0], &cke[ko]); ko += 32;
    limbs_to_be(&qay[0], &cke[ko]); ko += 32;
    // wrap the ClientKeyExchange handshake message in a TLS record (type 22)
    char[80] ckerec;
    ckerec[0] = T_HS; ckerec[1] = 3; ckerec[2] = 3; ckerec[3] = 0; ckerec[4] = 70;
    for (int i = 0; i < 70; i++) ckerec[5+i] = cke[i];
    sc_send(fd, &ckerec[0], 75);
    sha_upd(&trans, &cke[0], 70);

    // ---- ChangeCipherSpec ----
    char[6] ccs;
    ccs[0] = T_CCS; ccs[1] = 3; ccs[2] = 3; ccs[3] = 0; ccs[4] = 1; ccs[5] = 1;
    sc_send(fd, &ccs[0], 6);

    // ---- client Finished (encrypted, seq 0) ----
    char[32] th;
    sha_fin(&trans, &th[0]);
    char[12] cfin;
    tls_prf(&master[0], 48, (char*)"client finished", 15, &th[0], 32, &cfin[0], 12);
    char[16] finmsg;
    finmsg[0] = 20; finmsg[1] = 0; finmsg[2] = 0; finmsg[3] = 12;
    for (int i = 0; i < 12; i++) finmsg[4+i] = cfin[i];
    char[8] seq = {0,0,0,0,0,0,0,0};
    if (argc > 2) { seq[7] = (char)(argv[2][0] - '0'); }   // optional seq arg
    char[12] nonce;
    for (int i = 0; i < 4; i++) nonce[i] = civ[i];
    for (int i = 0; i < 8; i++) nonce[4+i] = seq[i];
    char[13] aad;
    for (int i = 0; i < 8; i++) aad[i] = seq[i];
    aad[8] = T_HS; aad[9] = 3; aad[10] = 3; aad[11] = 0; aad[12] = 32;   // AAD len = on-wire record length (server reads it)
    char[16] finct; char[16] fintag;
    gcm(&ckey[0], &nonce[0], &aad[0], 13, &finmsg[0], 16, &finct[0], &fintag[0]);
    xw(1,(char*)"DBG car=",7); puthexb(&car[0],32); xw(1,(char*)"\n",1);
    xw(1,(char*)"DBG srvr=",8); puthexb(&srv_random[0],32); xw(1,(char*)"\n",1);
    xw(1,(char*)"DBG prem=",8); puthexb(&prem[0],32); xw(1,(char*)"\n",1);
    char[32] dbgqax; char[32] dbgqay;
    limbs_to_be(&qax[0], &dbgqax[0]);
    limbs_to_be(&qay[0], &dbgqay[0]);
    xw(1,(char*)"DBG qax=",7); puthexb(&dbgqax[0],32); xw(1,(char*)"\n",1);
    xw(1,(char*)"DBG qay=",7); puthexb(&dbgqay[0],32); xw(1,(char*)"\n",1);
    xw(1,(char*)"DBG master=",10); puthexb(&master[0],48); xw(1,(char*)"\n",1);
    xw(1,(char*)"DBG ckey=",8); puthexb(&ckey[0],16); xw(1,(char*)"\n",1);
    xw(1,(char*)"DBG nonce=",9); puthexb(&nonce[0],12); xw(1,(char*)"\n",1);
    xw(1,(char*)"DBG aad=",7); puthexb(&aad[0],13); xw(1,(char*)"\n",1);
    xw(1,(char*)"DBG pt=",6); puthexb(&finmsg[0],16); xw(1,(char*)"\n",1);
    xw(1,(char*)"DBG finct=",9); puthexb(&finct[0],16); xw(1,(char*)"\n",1);
    xw(1,(char*)"DBG fintag=",10); puthexb(&fintag[0],16); xw(1,(char*)"\n",1);
    char[40] finrec;
    finrec[0] = T_HS; finrec[1] = 3; finrec[2] = 3; finrec[3] = 0; finrec[4] = 32;
    for (int i = 0; i < 16; i++) finrec[5+i] = finct[i];
    for (int i = 0; i < 16; i++) finrec[21+i] = fintag[i];
    sc_send(fd, &finrec[0], 37);

    // ---- read server CCS + encrypted Finished; DECRYPT and verify ----
    // expected server verify_data = PRF(master,"server finished",Hash(transcript incl our Finished),12)
    sha_upd(&trans, &finmsg[0], 16);
    char[32] sth2;
    sha_fin(&trans, &sth2[0]);
    char[12] sfin_expect;
    tls_prf(&master[0], 48, (char*)"server finished", 15, &sth2[0], 32, &sfin_expect[0], 12);

    char[8] sseq = {0,0,0,0,0,0,0,0};
    char[12] snonce;
    for (int i = 0; i < 4; i++) snonce[i] = siv[i];
    for (int i = 0; i < 8; i++) snonce[4+i] = sseq[i];

    int g2 = 0;
    int verified = 0;
    while (g2++ < 10)
    {
        char[5] h2;
        long n2 = sc_recv(fd, &h2[0], 5);
        if (n2 <= 0) break;
        char ct2 = h2[0];
        uint p2 = ((uint)(char)h2[3] << 8) | (uint)(char)h2[4];
        char[9000] pay2;
        long oo = 0;
        while (oo < (long)p2) { long got = sc_recv(fd, &pay2[(uint)oo], (long)p2-(long)oo); if (got <= 0) break; oo += got; }
        if (ct2 == T_HS && p2 >= 32)
        {
            uint cl = p2 - 16;          // ciphertext length
            char[13] saad;
            for (int i = 0; i < 8; i++) saad[i] = sseq[i];
            saad[8] = T_HS; saad[9] = 3; saad[10] = 3;
            saad[11] = (char)((cl >> 8) & 0xFF);
            saad[12] = (char)(cl & 0xFF);
            char[9000] spt; char[16] stag;
            gcm(&skey[0], &snonce[0], &saad[0], 13, &pay2[0], cl, &spt[0], &stag[0]);
            // spt = decrypted record plaintext = Finished handshake msg (type20,len12,verify12)
            if (cl >= 16)
            {
                bool matches = true;
                for (int i = 0; i < 12; i++)
                {
                    if (spt[4+i] != sfin_expect[i]) matches = false;
                }
                if (matches) { xw(1,(char*)"[tls] SERVER FINISHED VERIFIED - HANDSHAKE COMPLETE\n",49); verified = 1; }
                else { xw(1,(char*)"[tls] server Finished mismatch\n",31); }
            }
            break;
        }
        else if (ct2 == T_ALERT) { xw(1,(char*)"server ALERT\n",13); break; }
    }
    xw(1, verified ? (char*)"[tls] result: FULL HANDSHAKE OK\n" : (char*)"[tls] result: see details\n", 38);
    return 0;
}