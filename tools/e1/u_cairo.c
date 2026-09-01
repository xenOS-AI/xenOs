// E2: a real cairo 2D-graphics program runs IN xenOS from the ext4 ROOTFS.
// Renders a 32x32 ARGB surface, paints it red, reads back pixel[0].
#include <cairo/cairo.h>
#include <stdio.h>
int main(void)
{
    cairo_surface_t* s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 32, 32);
    if (cairo_surface_status(s) != CAIRO_STATUS_SUCCESS) { printf("[e2] cairo surface FAIL\n"); return 1; }
    cairo_t* cr = cairo_create(s);
    cairo_set_source_rgb(cr, 1.0, 0.0, 0.0);
    cairo_paint(cr);
    cairo_surface_flush(s);
    unsigned* px = (unsigned*)cairo_image_surface_get_data(s);
    unsigned v = px[0];
    printf("[e2] CAIRO: 32x32 ARGB surface rendered, pixel0=0x%08x\n", v);
    cairo_destroy(cr);
    cairo_surface_destroy(s);
    return (v == 0xFFFF0000u) ? 0 : 1;
}