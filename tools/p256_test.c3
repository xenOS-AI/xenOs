module p256_test;
// ============================================================================
// xenOS P-256 (secp256r1) scalar multiplication from scratch, for the TLS
// ECDHE key exchange. Field ops use 9-limb temps (values < 2p => a single
// compare/subtract) so modular add/double/sub are simple and correct. Splits
// into easy-to-verify parts. Freestanding, no libc. Numbers are uint32 limbs
// LITTLE-endian. Verified against a Python P-256 reference.
// ============================================================================

extern fn long lx_syscall(long n, long a, long b, long c, long d);
fn long xwrite(long fd, char* b, long n) { return lx_syscall(1, fd, (long)b, n, 0); }
fn void* memset(void* p, int v, ulong n) @export("memset") { char*q=(char*)p; for(ulong i=0;i<n;i++)q[i]=(char)v; return p; }

const uint N8 = 8;
uint[8] p  = {0xffffffff,0xffffffff,0xffffffff,0x00000000,0x00000000,0x00000000,0x00000001,0xffffffff};
uint[8] p_m2 = {0xfffffffd,0xffffffff,0xffffffff,0x00000000,0x00000000,0x00000000,0x00000001,0xffffffff};
uint[8] gx = {0xd898c296,0xf4a13945,0x2deb33a0,0x77037d81,0x63a440f2,0xf8bce6e5,0xe12c4247,0x6b17d1f2};
uint[8] gy = {0x37bf51f5,0xcbb64068,0x6b315ece,0x2bce3357,0x7c0f9e16,0x8ee7eb4a,0xfe1a7f9b,0x4fe342e2};

// compare two 8-limb numbers: -1 if a<b, 0 if a==b, 1 if a>b
fn int cmp8(uint* a, uint* b)
{
    for (int i = 7; i >= 0; i--)
    {
        if (a[i] > b[i]) return 1;
        if (a[i] < b[i]) return -1;
    }
    return 0;
}

// a = (a + b) mod p ; a,b < p  (result < p)
fn void mod_add(uint* a, uint* b)
{
    ulong carry = 0;
    uint[9] t;
    for (int i = 0; i < 8; i++)
    {
        ulong s = (ulong)a[i] + (ulong)b[i] + carry;
        t[i] = (uint)(s & 0xffffffff);
        carry = s >> 32;
    }
    t[8] = (uint)carry;
    // subtract p once (t < 2p)
    if (t[8] != 0 || cmp8(&t[0], &p[0]) >= 0)
    {
        ulong br = 0;
        for (int i = 0; i < 8; i++)
        {
            ulong d = (ulong)t[i] - (ulong)p[i] - br;
            t[i] = (uint)(d & 0xffffffff);
            br = (d >> 32) & 1;
        }
    }
    for (int i = 0; i < 8; i++) a[i] = t[i];
}

// a = (2*a) mod p
fn void mod_double(uint* a)
{
    mod_add(a, a);
}

// a = (a - b) mod p ; a,b < p
fn void mod_sub(uint* a, uint* b)
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
        // a - b + p  =  p - (b - a)
        uint[8] ba;
        ulong br = 0;
        for (int i = 0; i < 8; i++)
        {
            ulong d = (ulong)b[i] - (ulong)a[i] - br;
            ba[i] = (uint)(d & 0xffffffff);
            br = (d >> 32) & 1;
        }
        // a = P - ba
        br = 0;
        for (int i = 0; i < 8; i++)
        {
            ulong d = (ulong)p[i] - (ulong)ba[i] - br;
            a[i] = (uint)(d & 0xffffffff);
            br = (d >> 32) & 1;
        }
    }
}

fn void mp_copy(uint* d, uint* s) { for (int i=0;i<8;i++) d[i]=s[i]; }
fn void mp_zero(uint* a) { for (int i=0;i<8;i++) a[i]=0; }
fn uint mp_getbit(uint* a, uint i) { return (a[i/32] >> (i%32)) & 1; }

// r = a*b mod p  (shift-add)
fn void mod_mul(uint* r, uint* a, uint* b)
{
    uint[8] result; mp_zero(&result[0]);
    uint[8] t;      mp_copy(&t[0], a);
    for (uint i = 0; i < 256; i++)
    {
        if (mp_getbit(b, i) == 1) mod_add(&result[0], &t[0]);
        mod_double(&t[0]);
    }
    mp_copy(r, &result[0]);
}

// r = a^k mod p
fn void mod_pow(uint* r, uint* a, uint* k)
{
    uint[8] base; mp_copy(&base[0], a);
    uint[8] acc;  mp_zero(&acc[0]); acc[0] = 1;
    for (uint i = 0; i < 256; i++)
    {
        if (mp_getbit(k, i) == 1) mod_mul(&acc[0], &acc[0], &base[0]);
        mod_mul(&base[0], &base[0], &base[0]);
    }
    mp_copy(r, &acc[0]);
}

fn void mod_inv(uint* r, uint* a)
{
    mod_pow(r, a, &p_m2[0]);
}

// point in affine coords
fn void point_double(uint* rx, uint* ry, uint* px, uint* py)
{
    // num = 3*x^2 - 3 ; den = 2*y ; lam = num/den
    uint[8] x2; mod_mul(&x2[0], px, px);
    uint[8] num; mp_copy(&num[0], &x2[0]);
    mod_add(&num[0], &num[0]);      // 2x^2
    mod_add(&num[0], &x2[0]);       // 3x^2
    uint[8] three; mp_zero(&three[0]); three[0] = 3;
    mod_sub(&num[0], &three[0]);    // 3x^2 - 3
    uint[8] den; mp_copy(&den[0], py);
    mod_double(&den[0]);
    uint[8] deninv; mod_inv(&deninv[0], &den[0]);
    uint[8] lam; mod_mul(&lam[0], &num[0], &deninv[0]);
    // x3 = lam^2 - 2x
    uint[8] lsq; mod_mul(&lsq[0], &lam[0], &lam[0]);
    uint[8] twox; mp_copy(&twox[0], px); mod_double(&twox[0]);
    mod_sub(&lsq[0], &twox[0]);
    // y3 = lam*(x - x3) - y
    uint[8] xmx3; mp_copy(&xmx3[0], px);
    mod_sub(&xmx3[0], &lsq[0]);
    uint[8] y3; mod_mul(&y3[0], &lam[0], &xmx3[0]);
    mod_sub(&y3[0], py);
    mp_copy(rx, &lsq[0]); mp_copy(ry, &y3[0]);
}

// R = P + Q (affine); handles same-point -> double, and inverse -> infinity
fn void point_add(uint* rx, uint* ry, uint* inf,
                  uint* px, uint* py, uint pinf,
                  uint* qx, uint* qy, uint qinf)
{
    if (pinf == 1) { mp_copy(rx, qx); mp_copy(ry, qy); inf[0] = qinf; return; }
    if (qinf == 1) { mp_copy(rx, px); mp_copy(ry, py); inf[0] = 0; return; }
    bool samex = (cmp8(px, qx) == 0);
    if (samex)
    {
        if (cmp8(py, qy) == 0)
        {
            point_double(rx, ry, px, py);
            inf[0] = 0;
            return;
        }
        else { inf[0] = 1; return; }   // P + (-P)
    }
    // lam = (y2-y1)/(x2-x1)
    uint[8] dy; mp_copy(&dy[0], qy); mod_sub(&dy[0], py);
    uint[8] dx; mp_copy(&dx[0], qx); mod_sub(&dx[0], px);
    uint[8] dxinv; mod_inv(&dxinv[0], &dx[0]);
    uint[8] lam; mod_mul(&lam[0], &dy[0], &dxinv[0]);
    uint[8] lsq; mod_mul(&lsq[0], &lam[0], &lam[0]);
    mod_sub(&lsq[0], px);
    mod_sub(&lsq[0], qx);
    uint[8] x1mx3; mp_copy(&x1mx3[0], px);
    mod_sub(&x1mx3[0], &lsq[0]);
    uint[8] y3; mod_mul(&y3[0], &lam[0], &x1mx3[0]);
    mod_sub(&y3[0], py);
    mp_copy(rx, &lsq[0]); mp_copy(ry, &y3[0]);
    inf[0] = 0;
}

fn void load_d(uint* d)
{
    // d = 0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    // little-endian uint32 limbs: each 64-bit word 0x0123456789abcdef has
    // low32 = 0x89abcdef, high32 = 0x01234567.
    for (int i = 0; i < 8; i++)
    {
        d[i] = (i % 2 == 0) ? 0x89abcdef : 0x01234567;
    }
}

// R = k * G  (double-and-add, MSB first)
fn void scalar_mult(uint* rx, uint* ry, uint* k)
{
    uint[8] rxb; uint[8] ryb; uint rzinf = 1;
    for (int i = 255; i >= 0; i--)
    {
        // double R
        uint[8] nx; uint[8] ny; uint ni = 0;
        if (rzinf == 1) { /* stays infinity */ }
        else { point_double(&nx[0], &ny[0], &rxb[0], &ryb[0]); mp_copy(&rxb[0], &nx[0]); mp_copy(&ryb[0], &ny[0]); rzinf = 0; }
        // add G if bit set
        if (mp_getbit(k, (uint)i) == 1)
        {
            uint[8] ax; uint[8] ay; uint[1] ai;
            point_add(&ax[0], &ay[0], &ai[0], &rxb[0], &ryb[0], rzinf, &gx[0], &gy[0], 0);
            mp_copy(&rxb[0], &ax[0]); mp_copy(&ryb[0], &ay[0]);
            rzinf = (int)ai[0];
        }
    }
    // If result is infinity (shouldn't happen for valid k), leave a marker
    mp_copy(rx, &rxb[0]); mp_copy(ry, &ryb[0]);
}

// print a number as 64 lowercase hex chars
fn void print_hex(uint* a)
{
    char* he = (char*)"0123456789abcdef";
    for (int i = 7; i >= 0; i--)
    {
        for (int sh = 28; sh >= 0; sh -= 4)
        {
            char c = he[(a[i] >> sh) & 0xF];
            xwrite(1, &c, 1);
        }
    }
}

fn int xk_host_main(int argc, char** argv) @export("xk_host_main")
{
    (void)argc; (void)argv;
    uint[8] d;
    load_d(&d[0]);
    uint[8] qxp; uint[8] qyp;
    scalar_mult(&qxp[0], &qyp[0], &d[0]);
    xwrite(1, (char*)"qxp=", 3); print_hex(&qxp[0]); xwrite(1, (char*)"\n", 1);
    xwrite(1, (char*)"qyp=", 3); print_hex(&qyp[0]); xwrite(1, (char*)"\n", 1);
    xwrite(1, (char*)"EXPECT qxp=d8cd12ea5c67f2f8a00c1124893edcfa6754c4d6cede6be13bdf2295c810a97f\n", 68);
    xwrite(1, (char*)"EXPECT qyp=a5a89d2d2a360c0ca9a4d6c7c9ed4b28d3e199d6627f2e696d689c310a5b0f48\n", 68);
    return 0;
}