// E2: glib (the GTK foundation) runs in xenOS from the ext4 rootfs.
#include <glib.h>
#include <stdio.h>
int main(void)
{
    char* s = g_strdup_printf("glib %u.%u runs in xenOS", glib_major_version, glib_minor_version);
    printf("[e2-glib] %s\n", s);
    g_free(s);
    return 0;
}