module aesgcm_test;
// ============================================================================
// xenOS from-scratch AES-128 + AES-GCM (host self-test copy; the same code is
// used by the TLS client). Verified against NIST SP 800-38D vectors and OpenSSL.
// Freestanding, no libc, no SSE.
// ============================================================================

extern fn long lx_syscall(long n, long a, long b, long c, long d);
fn long xwrite(long fd, char* b, long n) { return lx_syscall(1, fd, (long)b, n, 0); }
fn void* memset(void* d, int v, ulong n) @export("memset") { char* p=(char*)d; for(ulong i=0;i<n;i++){p[i]=(char)v;} return d; }
fn void* memcpy(void* d, void* s, ulong n) @export("memcpy") { char* p=(char*)d; char* q=(char*)s; for(ulong i=0;i<n;i++){p[i]=q[i];} return d; }

char[256] aes_sbox =
{
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
   0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
};
char[11] aes_rcon = {0x00,0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36};

// ---- AES-128: expand key (16 bytes) -> 176 bytes of round keys (44 words) ----
// round_keys is an array of 11 uint32[4] word rows (w[0..43]).
fn void aes128_expand(char* key, uint* w)
{
    uint t;
    // first 4 words = key (big-endian)
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
            // RotWord + SubWord + Rcon
            uint rot = (t << 8) | (t >> 24);
            uint sub = ((uint)aes_sbox[(rot>>24)&0xFF] << 24) | ((uint)aes_sbox[(rot>>16)&0xFF] << 16) |
                       ((uint)aes_sbox[(rot>>8)&0xFF] << 8) | (uint)aes_sbox[rot&0xFF];
            t = sub ^ ((uint)aes_rcon[i/4] << 24);
        }
        w[i] = w[i-4] ^ t;
    }
}

fn uint p_unused_gmul_stub(uint a, uint b)
{
    return 0;
}

// xtime: multiply by x in GF(2^8) mod poly 0x11b
fn char xtime(char a)
{
    uint x = (uint)a & 0xFF;
    uint r = (x << 1) & 0xFF;
    if ((x & 0x80) != 0) r ^= 0x1b;
    return (char)r;
}

fn char gfmul(char aa, char bb)
{
    uint a = (uint)aa & 0xFF;
    uint b = (uint)bb & 0xFF;
    uint p = 0;
    while (b != 0)
    {
        if ((b & 1) != 0) p ^= a;
        uint hi = (a & 0x80);
        a = (a << 1) & 0xFF;
        if (hi != 0) a ^= 0x1b;
        b >>= 1;
    }
    return (char)(p & 0xFF);
}

// Encrypt one 16-byte block in place (also usable for the GCM H/J0 ops).
fn void aes128_encrypt_block(char* in, char* out, uint* w)
{
    char[16] s;
    for (int i = 0; i < 16; i++) s[i] = in[i];
    // AddRoundKey 0
    for (int c = 0; c < 4; c++)
    {
        s[c*4+0] = (char)(s[c*4+0] ^ (w[c] >> 24));
        s[c*4+1] = (char)(s[c*4+1] ^ ((w[c] >> 16) & 0xFF));
        s[c*4+2] = (char)(s[c*4+2] ^ ((w[c] >> 8) & 0xFF));
        s[c*4+3] = (char)(s[c*4+3] ^ (w[c] & 0xFF));
    }
    for (int r = 0; r < 10; r++)
    {
        // SubBytes
        for (int i = 0; i < 16; i++) s[i] = aes_sbox[(uint)s[i] & 0xFF];
        // ShiftRows: state row r (byte index r, r+4, r+8, r+12) shifted left by r
        char[16] sh;
        sh[0]=s[0]; sh[1]=s[5]; sh[2]=s[10]; sh[3]=s[15];      // row0 no shift (bytes 0..3 columns)
        sh[4]=s[4]; sh[5]=s[9]; sh[6]=s[14]; sh[7]=s[3];
        sh[8]=s[8]; sh[9]=s[13]; sh[10]=s[2]; sh[11]=s[7];
        sh[12]=s[12]; sh[13]=s[1]; sh[14]=s[6]; sh[15]=s[11];
        // MixColumns (all but last round)
        if (r < 9)
        {
            char[16] mc;
            for (int c = 0; c < 4; c++)
            {
                char a0 = sh[c*4+0];
                char a1 = sh[c*4+1];
                char a2 = sh[c*4+2];
                char a3 = sh[c*4+3];
                mc[c*4+0] = gfmul(a0,(char)2) ^ gfmul(a1,(char)3) ^ a2 ^ a3;
                mc[c*4+1] = a0 ^ gfmul(a1,(char)2) ^ gfmul(a2,(char)3) ^ a3;
                mc[c*4+2] = a0 ^ a1 ^ gfmul(a2,(char)2) ^ gfmul(a3,(char)3);
                mc[c*4+3] = gfmul(a0,(char)3) ^ a1 ^ a2 ^ gfmul(a3,(char)2);
            }
            for (int i = 0; i < 16; i++) sh[i] = mc[i];
        }
        for (int i = 0; i < 16; i++) s[i] = sh[i];
        // AddRoundKey
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

// ---- AES-GCM (RFC 8452 / NIST). No AAD support (TLS uses empty AAD). ----
fn void gf_mult(char* x, char* y, char* z)
{
    // z = x (128-bit) * y (128-bit) in GF(2^128), for GHASH
    char[16] v;
    memset(&v[0],0,16);
    memset(&z[0],0,16);
    for (int i = 0; i < 16; i++) v[i] = x[i];
    for (int i = 0; i < 128; i++)
    {
        // z ^= v if y bit i (128-1-i from MSB) set
        uint byt = (uint)(i / 8);
        uint bit = (uint)(7 - (i % 8));
        if ((((uint)y[byt] >> bit) & 1) != 0)
        {
            for (int j = 0; j < 16; j++) z[j] = (char)(z[j] ^ v[j]);
        }
        // v = v * x mod poly (x^128 + x^7 + x^2 + x + 1)
        char lsb = (char)(v[15] & 1);
        for (int j = 15; j > 0; j--) v[j] = (char)(((uint)((char)v[j]) >> 1) | (((uint)((char)v[j-1]) & 1) << 7));
        v[0] = (char)((uint)((char)v[0]) >> 1);
        if (lsb != 0) { v[0] = (char)(v[0] ^ 0xE1); }
    }
}

// reverse the bit order within one byte
fn char bitrev_byte(char b)
{
    uint x = (uint)b & 0xFF;
    uint r = 0;
    for (int i = 0; i < 8; i++)
    {
        r = (r << 1) | (x & 1);
        x >>= 1;
    }
    return (char)r;
}

// bit-reverse a 128-bit block: reverse both the byte order and each byte's bits
fn void bitrev128(char* in, char* out)
{
    for (int i = 0; i < 16; i++) out[15 - i] = bitrev_byte(in[i]);
}

fn void ghash(char* h, char* data, uint len, char* out)
{
    // out (16) = GHASH of data (multiple of 16 bytes needed; caller pads).
    // gf_mult is already the GCM-convention (bit-reflected) multiply, so use it
    // directly on the natural blocks.
    memset(&out[0],0,16);
    for (uint i = 0; i + 16 <= len; i += 16)
    {
        for (int j = 0; j < 16; j++) out[j] = (char)(out[j] ^ data[(uint)i + (uint)j]);
        char[16] t;
        gf_mult(&out[0], h, &t[0]);
        for (int j = 0; j < 16; j++) out[j] = t[j];
    }
}

fn void aes128_gcm_encrypt(char* key, char* iv12, char* pt, uint plen, char* ct, char* tag)
{
    uint[44] w;
    aes128_expand(key, &w[0]);
    // H = E(K, 0^128)
    char[16] zero;
    memset(&zero[0],0,16);
    char[16] hkey;
    aes128_encrypt_block(&zero[0], &hkey[0], &w[0]);
    // J0 = IV || 0^31 || 1
    char[16] j0;
    for (int i = 0; i < 12; i++) j0[i] = iv12[i];
    j0[12] = 0; j0[13] = 0; j0[14] = 0; j0[15] = 1;
    // CTR encryption: counter = J0 with lowest word incremented starting from 2
    char[16] ej0;
    aes128_encrypt_block(&j0[0], &ej0[0], &w[0]);
    uint blocks = (plen + 15) / 16;
    for (uint b = 0; b < blocks; b++)
    {
        char[16] ctr;
        uint inc = (uint)(b + 2);
        // rebuild counter: J0 with low 32-bit = j0_low + b + 1
        for (int i = 0; i < 12; i++) ctr[i] = j0[i];
        uint low = 1 + b + 1 - 1; // J0 low word = 1; block b counter low = 1 + (b+1) -... 
        // counter for block 0 = J0 + 1 => low = 2
        uint cnt = (uint)(b + 2);
        ctr[12] = (char)(cnt >> 24); ctr[13] = (char)((cnt >> 16) & 0xFF);
        ctr[14] = (char)((cnt >> 8) & 0xFF); ctr[15] = (char)(cnt & 0xFF);
        char[16] stream;
        aes128_encrypt_block(&ctr[0], &stream[0], &w[0]);
        for (int j = 0; j < 16; j++)
        {
            uint idx = b * 16 + (uint)j;
            if (idx < plen) ct[idx] = (char)(pt[idx] ^ stream[j]);
        }
    }
    // Tag = E(K,J0) ^ GHASH(H, AAD||0-pad||CT||[lenAAD:64][lenCT:64])
    // build message for GHASH: CT padded to 16, then 16 bytes length block
    char[1024] gd;
    uint gl = 0;
    uint pad = plen + (16 - (plen % 16)) % 16;
    for (uint i = 0; i < plen; i++) gd[gl++] = ct[i];
    for (uint i = plen; i < pad; i++) gd[gl++] = 0;
    for (int i = 0; i < 8; i++) gd[gl++] = 0;                       // lenAAD = 0 (64-bit)
    ulong bitlen = (ulong)plen * 8;
    for (int i = 7; i >= 0; i--) gd[gl++] = (char)((bitlen >> (i * 8)) & 0xFF);  // lenCT
    char[16] g;
    ghash(&hkey[0], &gd[0], gl, &g[0]);
    for (int i = 0; i < 16; i++) tag[i] = (char)(ej0[i] ^ g[i]);
}

// AAD-capable GCM (used by TLS records): same as above but GHASH over
// AAD(pad) || CT(pad) || [lenA:8][lenC:8].
fn void gcm_aad(char* key, char* iv12, char* aad, uint aadlen, char* pt, uint plen, char* ct, char* tag)
{
    uint[44] w;
    aes128_expand(key, &w[0]);
    char[16] zero;
    memset(&zero[0],0,16);
    char[16] hkey;
    aes128_encrypt_block(&zero[0], &hkey[0], &w[0]);
    char[16] j0;
    for (int i = 0; i < 12; i++) j0[i] = iv12[i];
    j0[12] = 0; j0[13] = 0; j0[14] = 0; j0[15] = 1;
    char[16] ej0;
    aes128_encrypt_block(&j0[0], &ej0[0], &w[0]);
    uint blocks = (plen + 15) / 16;
    for (uint b = 0; b < blocks; b++)
    {
        char[16] ctr;
        for (int i = 0; i < 12; i++) ctr[i] = j0[i];
        uint cnt = (uint)(b + 2);
        ctr[12] = (char)(cnt >> 24); ctr[13] = (char)((cnt >> 16) & 0xFF);
        ctr[14] = (char)((cnt >> 8) & 0xFF); ctr[15] = (char)(cnt & 0xFF);
        char[16] stream;
        aes128_encrypt_block(&ctr[0], &stream[0], &w[0]);
        for (int j = 0; j < 16; j++)
        {
            uint idx = b * 16 + (uint)j;
            if (idx < plen) ct[idx] = (char)(pt[idx] ^ stream[j]);
        }
    }
    char[1024] gd;
    uint gl = 0;
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
    char[16] g;
    ghash(&hkey[0], &gd[0], gl, &g[0]);
    for (int i = 0; i < 16; i++) tag[i] = (char)(ej0[i] ^ g[i]);
}

// ---- test: NIST AES-128-GCM vector ---- 
fn void puthexb(char* d, uint n)
{
    char* he=(char*)"0123456789abcdef";
    for (uint i=0;i<n;i++){ char c; c=he[((int)d[i]>>4)&0xF]; xwrite(1,&c,1); c=he[(int)d[i]&0xF]; xwrite(1,&c,1);} 
}

fn void test_gcm()
{
    // ---- authoritative check: empty key/IV/PT, empty AAD ----
    // NIST GCM vector: tag 58e2fccefa7e3061367f1d57a4e7455a
    {
        char[16] zkey; memset(&zkey[0],0,16);
        char[12] ziv;  memset(&ziv[0],0,12);
        char[1] zctB; char[16] ztag;
        aes128_gcm_encrypt(&zkey[0], &ziv[0], (char*)"", 0, &zctB[0], &ztag[0]);
        xwrite(1,(char*)"EMPTY TAG = ",12); puthexb(&ztag[0],16); xwrite(1,(char*)"\n",1);
        xwrite(1,(char*)"  expect 58e2fccefa7e3061367f1d57a4e7455a\n",38);
    }
    // ---- AAD-bearing case vs OpenSSL EVP ----
    {
        // key=000102..0f nonce=000102030405060708090a0b aad=00000000000000001603030010 pt=00..0f(16)
        char[16] key = {0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f};
        char[12] iv  = {0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b};
        char[13] aad = {0,0,0,0,0,0,0,0,0x16,0x03,0x03,0x00,0x10};
        char[16] pt;
        for (int i=0;i<16;i++) pt[i]=(char)i;
        char[16] ct; char[16] tag;
        gcm_aad(&key[0],&iv[0],&aad[0],13,&pt[0],16,&ct[0],&tag[0]);
        xwrite(1,(char*)"AAD CT = ",9); puthexb(&ct[0],16); xwrite(1,(char*)"\n",1);
        xwrite(1,(char*)"AAD TAG= ",9); puthexb(&tag[0],16); xwrite(1,(char*)"\n",1);
    }
    // ---- gf_mult convention check vs a python reference ----
    char[16] ga = {0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0x10};
    char[16] gb = {0xfe,0xed,0xfa,0xce,0xca,0xfe,0xbe,0xef,0x00,0xff,0x00,0xff,0x00,0xff,0x00,0xff};
    char[16] gz;
    gf_mult(&ga[0], &gb[0], &gz[0]);
    xwrite(1,(char*)"GFMUL = ",8); puthexb(&gz[0],16); xwrite(1,(char*)"\n",1);
    xwrite(1,(char*)"  expect 50de34673808c92d9c7fdf6543998932\n",39);
    // NIST vector: K=feffe9928665731c6d6a8f9467308308 IV=cafebabefacedbaddecaf888
    char[16] key = {0xfe,0xff,0xe9,0x92,0x86,0x65,0x73,0x1c,0x6d,0x6a,0x8f,0x94,0x67,0x30,0x83,0x08};
    char[12] iv  = {0xca,0xfe,0xba,0xbe,0xfa,0xce,0xdb,0xad,0xde,0xca,0xf8,0x88};
    char[60] pt = {0xd9,0x31,0x32,0x25,0xf8,0x84,0x06,0xe5,0xa5,0x59,0x09,0xc5,0xaf,0xf5,0x26,0x9a,
                   0x86,0xa7,0xa9,0x53,0x15,0x34,0xf7,0xda,0x2e,0x4c,0x30,0x3d,0x8a,0x31,0x8a,0x72,
                   0x1c,0x3c,0x0c,0x95,0x95,0x68,0x09,0x53,0x2f,0xcf,0x0e,0x24,0x49,0xa6,0xb5,0x25,
                   0xb1,0x6a,0xed,0xf5,0xaa,0x0d,0xe6,0x57,0xba,0x63,0x7b,0x39};
    char[60] ct;
    char[16] tag;
    aes128_gcm_encrypt(&key[0], &iv[0], &pt[0], 60, &ct[0], &tag[0]);
        xwrite(1,(char*)"CT  = ",6); puthexb(&ct[0],60); xwrite(1,(char*)"\n",1);
        xwrite(1,(char*)"TAG = ",6); puthexb(&tag[0],16); xwrite(1,(char*)"\n",1);
        // ---- debug internals: verify the FULL NIST vector (which HAS a 20-byte AAD) ----
        {
            uint[44] w; aes128_expand(&key[0], &w[0]);
            char[16] zero; memset(&zero[0],0,16);
            char[16] hk; aes128_encrypt_block(&zero[0], &hk[0], &w[0]);
            char[16] j0; for (int i=0;i<12;i++) j0[i]=iv[i]; j0[12]=0;j0[13]=0;j0[14]=0;j0[15]=1;
            char[16] ej0; aes128_encrypt_block(&j0[0], &ej0[0], &w[0]);
            // GHASH msg = AAD[20] padded to 32  || CT[60] padded to 64  || len(A)=20*8 || len(C)=60*8
            char* aad = (char*)"\xfe\xed\xfa\xce\xde\xad\xbe\xef\xfe\xed\xfa\xce\xde\xad\xbe\xef\xab\xad\xda\xd2";
            char[128] gd; uint gl=0;
            for (int i=0;i<20;i++) gd[gl++]=aad[i];
            for (int i=20;i<32;i++) gd[gl++]=0;
            for (int i=0;i<60;i++) gd[gl++]=ct[i];
            for (int i=60;i<64;i++) gd[gl++]=0;
            ulong lena=20*8; for (int i=7;i>=0;i--) gd[gl++]=(char)((lena>>(i*8))&0xFF);
            ulong lenc=60*8; for (int i=7;i>=0;i--) gd[gl++]=(char)((lenc>>(i*8))&0xFF);
            char[16] gg; ghash(&hk[0], &gd[0], gl, &gg[0]);
            char[16] gtx; for (int i=0;i<16;i++) gtx[i]=(char)(ej0[i]^gg[i]);
            xwrite(1,(char*)"H      = ",9); puthexb(&hk[0],16); xwrite(1,(char*)"\n",1);
            xwrite(1,(char*)"E(J0)  = ",9); puthexb(&ej0[0],16); xwrite(1,(char*)"\n",1);
            xwrite(1,(char*)"GHASH  = ",9); puthexb(&gg[0],16); xwrite(1,(char*)"\n",1);
            xwrite(1,(char*)"E^GHASH= ",9); puthexb(&gtx[0],16); xwrite(1,(char*)"\n",1);
        }
        xwrite(1,(char*)"EXPECT CT = 42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985\n",92);
        xwrite(1,(char*)"EXPECT TAG (full vector w/ AAD)= 4d5c2af327cd64a62cf35abd2ba6fab4\n",51);
    }

fn int xk_host_main(int argc, char** argv) @export("xk_host_main")
{
    (void)argc; (void)argv;
    test_gcm();
    return 0;
}