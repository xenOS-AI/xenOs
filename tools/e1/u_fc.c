// E2: fontconfig (the GTK text/font-config layer) runs in xenOS from the rootfs.
#include <fontconfig/fontconfig.h>
#include <stdio.h>
int main(void)
{
    if (!FcInit()) { printf("[e2-fc] FcInit FAIL\n"); return 1; }
    FcConfig* cfg = FcConfigGetCurrent();
    FcFontSet* fs = FcConfigGetFonts(cfg, FcSetSystem);
    printf("[e2-fc] fontconfig init OK, system fontset=%s\n", fs ? "ready" : "empty");
    return 0;
}