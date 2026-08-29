module xk;

// ============================================================================
// xenOS TLS 1.2 PRF (P_SHA256) from scratch — the key-derivation function that
// turns the pre-master secret + client/server randoms into the master secret
// and then the working MAC/encryption keys. Built entirely on hmac_sha256()
// (RFC 2104, verified). RFC 5246 §5.
// ============================================================================

// TLS 1.2 P_hash: out = HMAC(A(1)+data) || HMAC(A(2)+data) || ...
// where A(0)=seed(data's first block), A(i)=HMAC(secret, A(i-1)), and
// data = label || seed. This implementation stretches to outlen bytes.
fn void tls_prf(char* secret, uint slen, char* label, uint llen,
                char* seed, uint seedlen, char* out, uint outlen)
{
    // data = label || seed
    char[512] data;
    uint dlen = 0;
    for (uint i = 0; i < llen && dlen < 510; i++) data[dlen++] = label[i];
    for (uint i = 0; i < seedlen && dlen < 510; i++) data[dlen++] = seed[i];

    // A(1) = HMAC(secret, data)   [seed in TLS P_hash is the whole data block]
    char[32] a;
    hmac_sha256(secret, slen, &data[0], dlen, &a[0]);

    uint produced = 0;
    while (produced < outlen)
    {
        // tmp = A(i) || data
        char[544] tmp;
        uint tlen = 0;
        for (int i = 0; i < 32; i++) tmp[tlen++] = a[i];
        for (uint i = 0; i < dlen && tlen < 543; i++) tmp[tlen++] = data[i];

        char[32] block;
        hmac_sha256(secret, slen, &tmp[0], tlen, &block[0]);
        for (int i = 0; i < 32 && produced < outlen; i++)
        {
            out[produced++] = block[i];
        }
        if (produced >= outlen) break;

        // A(i+1) = HMAC(secret, A(i))
        char[32] anext;
        hmac_sha256(secret, slen, &a[0], 32, &anext[0]);
        for (int i = 0; i < 32; i++) a[i] = anext[i];
    }
}

// Master secret: PRF(pre_master_secret, "master secret", client_random + server_random)
fn void tls_master_secret(char* pre, uint plen, char* cr, char* sr, char* out48)
{
    char[64] seed;
    for (int i = 0; i < 32; i++) seed[i] = cr[i];
    for (int i = 0; i < 32; i++) seed[32 + i] = sr[i];
    tls_prf(pre, plen, (char*)"master secret", 13, &seed[0], 64, out48, 48);
}

// Key block: PRF( master_secret, "key expansion", server_random + client_random )
// outlen is the total (2*mac + 2*key + 2*iv) needed by the negotiated suite.
fn void tls_key_block(char* ms, char* sr, char* cr, char* out, uint outlen)
{
    char[64] seed;
    for (int i = 0; i < 32; i++) seed[i] = sr[i];
    for (int i = 0; i < 32; i++) seed[32 + i] = cr[i];
    tls_prf(ms, 48, (char*)"key expansion", 13, &seed[0], 64, out, outlen);
}

// ---- boot-time self-test: compare against a reference P_SHA256 output ----
fn void tls_prf_selftest()
{
    // secret = 01 02 03 04 05, label="key expansion", seed = aa*32 || bb*32,
    // stretch 96 bytes. Reference produced by CPython's hmac/hashlib:
    // de9e435909ced03a5fc630549fd54e109dbca81b68b2f81da202f0c1fe993c3708a3b2
    // af7581e26ecf4a5af556a25030266dbd6b289fa47c3e30a4f2ff5e47fbc061216667768
    // 835327462adc1a88bf821e2c72aeb856a37bd02fd5ed7625f7f
    char[5] secret;
    secret[0] = 0x01; secret[1] = 0x02; secret[2] = 0x03; secret[3] = 0x04; secret[4] = 0x05;
    char[64] seed;
    for (int i = 0; i < 32; i++) seed[i] = (char)0xaa;
    for (int i = 32; i < 64; i++) seed[i] = (char)0xbb;
    char[96] out;
    tls_prf(&secret[0], 5, (char*)"key expansion", 13, &seed[0], 64, &out[0], 96);
    char* ref = (char*)"de9e435909ced03a5fc630549fd54e109dbca81b68b2f81da202f0c1fe993c3708a3b2af7581e26ecf4a5af556a25030266dbd6b289fa47c3e30a4f2ff5e47fbc061216667768835327462adc1a88bf821e2c72aeb856a37bd02fd5ed7625f7f";
    bool ok = true;
    for (int i = 0; i < 96; i++)
    {
        uint hi = 0;
        uint lo = 0;
        char c = ref[i * 2];
        if (c >= '0' && c <= '9') { hi = (uint)(c - '0'); }
        else { hi = (uint)(10 + (c - 'a')); }
        c = ref[i * 2 + 1];
        if (c >= '0' && c <= '9') { lo = (uint)(c - '0'); }
        else { lo = (uint)(10 + (c - 'a')); }
        if (out[i] != (char)((hi << 4) | lo)) ok = false;
    }
    xk_puts("[tls] PRF P_SHA256 96 bytes = ");
    for (int i = 0; i < 32; i++) xk_put_hex_byte(out[i]);
    for (int i = 32; i < 96; i++) xk_put_hex_byte(out[i]);
    xk_puts(ok ? "  PASS\r\n" : "  FAIL\r\n");
}