module xk;

// ============================================================================
// xenOS from-scratch AES-128 + AES-GCM (NIST SP 800-38D) for the TLS stack.
// Verified: the empty-input tag 58e2fcce... matches the authoritative NIST GCM
// vector; the 60-byte NIST ciphertext matches OpenSSL exactly. Same code as
// tools/aesgcm_test.c3 (byte-identical), ported into the kernel. Freestanding.
// ============================================================================

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

fn char aes_gfmul(char aa, char bb)
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

fn void aes128_expand(char* key, uint* w)
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
            uint rot = (t << 8) | (t >> 24);
            uint sub = ((uint)aes_sbox[(rot>>24)&0xFF] << 24) | ((uint)aes_sbox[(rot>>16)&0xFF] << 16) |
                       ((uint)aes_sbox[(rot>>8)&0xFF] << 8) | (uint)aes_sbox[rot&0xFF];
            t = sub ^ ((uint)aes_rcon[i/4] << 24);
        }
        w[i] = w[i-4] ^ t;
    }
}

fn void aes128_encrypt_block(char* in, char* out, uint* w)
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
        for (int i = 0; i < 16; i++) s[i] = aes_sbox[(uint)s[i] & 0xFF];
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
                mc[c*4+0] = aes_gfmul(a0,(char)2) ^ aes_gfmul(a1,(char)3) ^ a2 ^ a3;
                mc[c*4+1] = a0 ^ aes_gfmul(a1,(char)2) ^ aes_gfmul(a2,(char)3) ^ a3;
                mc[c*4+2] = a0 ^ a1 ^ aes_gfmul(a2,(char)2) ^ aes_gfmul(a3,(char)3);
                mc[c*4+3] = aes_gfmul(a0,(char)3) ^ a1 ^ a2 ^ aes_gfmul(a3,(char)2);
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

// GHASH GF(2^128) multiply (GCM bit-reflected convention).
fn void aes_gfmult(char* x, char* y, char* z)
{
    char[16] v;
    memset(&v[0],0,16);
    memset(&z[0],0,16);
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
        if (lsb != 0) { v[0] = (char)((uint)v[0] ^ 0xE1); }
    }
}

fn void aes_ghash(char* h, char* data, uint len, char* out)
{
    memset(&out[0],0,16);
    for (uint i = 0; i + 16 <= len; i += 16)
    {
        for (int j = 0; j < 16; j++) out[j] = (char)(out[j] ^ data[(uint)i + (uint)j]);
        char[16] t;
        aes_gfmult(&out[0], h, &t[0]);
        for (int j = 0; j < 16; j++) out[j] = t[j];
    }
}

// AES-128-GCM encrypt, empty AAD (TLS application data). Produces ct[] and tag[].
fn void aes128_gcm_encrypt(char* key, char* iv12, char* pt, uint plen, char* ct, char* tag)
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
            if (idx < plen) ct[idx] = (char)(pt[idx] ^ (stream[j]));
        }
    }
    char[2048] gd;
    uint gl = 0;
    uint padct = plen + (16 - (plen % 16)) % 16;
    for (uint i = 0; i < plen; i++) gd[gl++] = ct[i];
    for (uint i = plen; i < padct; i++) gd[gl++] = 0;
    ulong bitlen = (ulong)plen * 8;
    for (int i = 0; i < 8; i++) gd[gl++] = 0;                           // len(A) = 0
    for (int i = 7; i >= 0; i--) gd[gl++] = (char)((bitlen >> (i * 8)) & 0xFF);  // len(C)
    char[16] g;
    aes_ghash(&hkey[0], &gd[0], gl, &g[0]);
    for (int i = 0; i < 16; i++) tag[i] = (char)((char)ej0[i] ^ g[i]);
}

// boot-time self-test: authoritative NIST empty-input GCM tag
fn void aes_gcm_selftest()
{
    char[16] zkey; kmemzero(&zkey[0], 16);
    char[12] ziv;  kmemzero(&ziv[0], 12);
    char[1] zctB; char[16] ztag;
    aes128_gcm_encrypt(&zkey[0], &ziv[0], (char*)"", 0, &zctB[0], &ztag[0]);
    bool ok = hex16_matches(&ztag[0], (char*)"58e2fccefa7e3061367f1d57a4e7455a");
    xk_puts("[aes] GCM empty tag = ");
    for (int i = 0; i < 16; i++) xk_put_hex_byte(ztag[i]);
    xk_puts(ok ? "  PASS (NIST)\r\n" : "  FAIL\r\n");
}