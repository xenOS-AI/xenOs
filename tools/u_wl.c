// xenOS: the real, CROSS-BUILT libwayland-client running INSIDE the kernel's
// userland. wl_display_connect(NULL) attempts a unix-socket connect to the
// Wayland display; with no compositor running it must return NULL cleanly.
#include <wayland-client.h>
#include <unistd.h>

static void reg_global(void *d, struct wl_registry *r, uint32_t n, const char *i, uint32_t v)
{ (void)d; (void)r; (void)n; (void)i; (void)v; }
static void reg_global_remove(void *d, struct wl_registry *r, uint32_t n)
{ (void)d; (void)r; (void)n; }

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

int main(void)
{
    say("[wl] libwayland-client inside xenOS\n");
    struct wl_display *d = wl_display_connect(NULL);
    if (!d) {
        say("[wl] wl_display_connect -> NULL (no server, expected)\n");
        return 0;
    }
    wl_display_disconnect(d);
    say("[wl] connected (unexpected without a server)\n");
    return 1;
}