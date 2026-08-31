// xenOS Phase D interop gate: a REAL libwayland-client (cross-built) connects to
// the KERNEL Wayland compositor on /run/wayland-0, reads the advertised globals,
// and completes wl_display_roundtrip() against the wire. Success = genuine
// Wayland-protocol interoperability between the client we build and xenOS.
#include <wayland-client.h>
#include <stdio.h>
#include <stdlib.h>

static void reg_handle(void* d, struct wl_registry* r, uint32_t name, const char* itf, uint32_t ver)
{
    (void)d; (void)r;
    printf("  [wl] global %u %s v%u\n", name, itf, ver);
}
static void reg_done(void* d, struct wl_registry* r, uint32_t name) { (void)d; (void)r; (void)name; }

int main(void)
{
    setenv("XDG_RUNTIME_DIR", "/run", 1);
    struct wl_display* d = wl_display_connect(NULL);
    if (!d) { printf("[wl] FAIL connect (no display socket)\n"); return 3; }
    printf("[wl] connected to /run/wayland-0\n");
    struct wl_registry* r = wl_display_get_registry(d);
    struct wl_registry_listener li = { reg_handle, reg_done };
    wl_registry_add_listener(r, &li, NULL);
    int rc = wl_display_roundtrip(d);
    printf("[wl] roundtrip rc=%d -> %s\n", rc, rc == 0 ? "INTEROP OK" : "FAIL");
    wl_display_disconnect(d);
    printf("[wl] DONE\n");
    return 0;
}