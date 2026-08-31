// xenOS first real external-library userland test (Phase D): a static-musl binary
// linked against the CROSS-BUILT libffi. Bundled as the kernel boot blob; runs the
// exact ffi_call marshalling path libwayland uses and prints res=42 from inside xenOS.
#include <stdio.h>
#include <ffi.h>
int add2(int a, int b) { return a + b; }
int main(void)
{
    ffi_cif cif;
    ffi_type *args[2] = { &ffi_type_sint, &ffi_type_sint };
    if (ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 2, &ffi_type_sint, args) != FFI_OK) return 1;
    int a = 20, b = 22, res = 0;
    void *vals[2] = { &a, &b };
    ffi_call(&cif, FFI_FN(add2), &res, vals);
    printf("libffi static-musl inside xenOS res=%d (expect 42)\n", res);
    return res == 42 ? 0 : 2;
}