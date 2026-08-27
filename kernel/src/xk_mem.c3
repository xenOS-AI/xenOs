module xk;

// ============================================================================
// Thin libc memory helpers exported under the exact linker names the C3/LLVM
// codegen emits (memset/memcpy/memmove), so the freestanding kernel needs no
// libc. Values are exact symbol names via @export("...").  Scalar, no SIMD.
// ============================================================================

fn void* memset(void* s, int c, ulong n) @export("memset")
{
    char* p = (char*)s;
    for (ulong i = 0; i < n; i++) { p[i] = (char)c; }
    return (void*)s;
}

fn void* memcpy(void* dst, void* src, ulong n) @export("memcpy")
{
    char* d = (char*)dst;
    char* s = (char*)src;
    for (ulong i = 0; i < n; i++) { d[i] = s[i]; }
    return (void*)dst;
}

fn void* memmove(void* dst, void* src, ulong n) @export("memmove")
{
    char* d = (char*)dst;
    char* s = (char*)src;
    if (d < s)
    {
        for (ulong i = 0; i < n; i++) { d[i] = s[i]; }
    }
    else
    {
        for (ulong i = n; i > 0; i--) { d[i - 1] = s[i - 1]; }
    }
    return (void*)dst;
}

fn int memcmp(void* a, void* b, ulong n) @export("memcmp")
{
    char* x = (char*)a;
    char* y = (char*)b;
    for (ulong i = 0; i < n; i++)
    {
        if (x[i] != y[i]) { return (int)x[i] - (int)y[i]; }
    }
    return 0;
}