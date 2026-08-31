// xenOS Phase D: an UNMODIFIED Wayland client (libwayland-client API) draws to the
// kernel compositor: get_registry -> bind wl_compositor+wl_shm -> create a /dev/shm
// pool (open+mmap MAP_SHARED+paint) -> create_surface/pool/buffer -> attach -> commit.
#include <wayland-client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#define W 320
#define H 240
static struct wl_compositor* comp;
static struct wl_shm* shm;
static void reg_global(void* d, struct wl_registry* r, uint32_t name, const char* itf, uint32_t ver)
{
    (void)d;
    if (!strcmp(itf, "wl_compositor")) comp = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (!strcmp(itf, "wl_shm"))   shm   = wl_registry_bind(r, name, &wl_shm_interface, 1);
}
static void reg_remove(void* d, struct wl_registry* r, uint32_t n) { (void)d;(void)r;(void)n; }
int main(void)
{
    setenv("XDG_RUNTIME_DIR", "/run", 1);
    struct wl_display* d = wl_display_connect(NULL);
    if (!d) { printf("[app] connect FAIL\n"); return 3; }
    struct wl_registry* r = wl_display_get_registry(d);
    struct wl_registry_listener li = { reg_global, reg_remove };
    wl_registry_add_listener(r, &li, NULL);
    wl_display_roundtrip(d);
    if (!comp || !shm) { printf("[app] missing globals comp=%p shm=%p\n", (void*)comp, (void*)shm); return 3; }
    printf("[app] bound wl_compositor + wl_shm\n");

    int fd = open("/dev/shm/xpool", O_CREAT|O_RDWR, 0600);
    if (fd < 0) { printf("[app] open /dev/shm/xpool FAIL\n"); return 3; }
    unsigned char* px = mmap(0, W*H*4, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == (void*)-1) { printf("[app] mmap FAIL\n"); return 3; }
    int x, y;
    for (y=0;y<H;y++) for (x=0;x<W;x++) { unsigned o=(y*W+x)*4; px[o]=0x10; px[o+1]=0x30; px[o+2]=0xF0; px[o+3]=0xFF; }
    printf("[app] painted %dx%d pool fd=%d px=%p\n", W, H, fd, (void*)px);

    struct wl_surface* s = wl_compositor_create_surface(comp);
    struct wl_shm_pool* pool = wl_shm_create_pool(shm, fd, W*H*4);
    struct wl_buffer* buf = wl_shm_pool_create_buffer(pool, 0, W, H, W*4, 0x34325258); /* XRGB8888 */
    wl_surface_attach(s, buf, 0, 0);
    wl_surface_commit(s);
    wl_display_roundtrip(d);
    printf("[app] surface attach+commit sent; compositor should PRESENT it\n");
    return 0;
}