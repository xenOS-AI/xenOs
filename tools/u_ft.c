// xenOS Phase E: the cross-built libfreetype.a runs the real FT API inside xenOS.
#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdio.h>
int main(void)
{
    FT_Library lib;
    int err = FT_Init_FreeType(&lib);
    if (err) { printf("[ft] FT_Init_FreeType FAIL err=%d\n", err); return 1; }
    int mj, mn, pt;
    FT_Library_Version(lib, &mj, &mn, &pt);
    printf("[ft] FreeType %d.%d.%d initialized OK in xenOS\n", mj, mn, pt);
    FT_Done_FreeType(lib);
    return 0;
}