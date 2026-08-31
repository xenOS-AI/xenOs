// xenOS Phase D: drive the FULL Wayland SHM surface path against the kernel
// compositor -- get_registry, bind wl_shm+wl_compositor, create_surface,
// create_pool (pixel base), create_buffer, attach, commit -- then the kernel
// blits the MAP_SHARED buffer to the framebuffer. Real wire protocol messages.
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>

#define W 320
#define H 240

static void wl32(unsigned char* m, int o, unsigned v){ m[o]=v&0xFF; m[o+1]=(v>>8)&0xFF; m[o+2]=(v>>16)&0xFF; m[o+3]=(v>>24)&0xFF; }

int main(void)
{
    setenv("XDG_RUNTIME_DIR", "/run", 1);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
    strncpy(a.sun_path, "/run/wayland-0", sizeof a.sun_path - 1);
    if (connect(fd, (struct sockaddr*)&a, sizeof a) != 0) { printf("[wl] connect FAIL\n"); return 2; }

    /* shared pixel pool */
    unsigned char* pool = mmap(0, W*H*4, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_ANONYMOUS, -1, 0);
    if (pool == (void*)-1) { printf("[wl] mmap FAIL\n"); return 2; }
    int x, y;
    for (y = 0; y < H; y++) for (x = 0; x < W; x++) {
        unsigned o = (y*W + x)*4;
        if (x < W/3)      { pool[o]=0x10; pool[o+1]=0x20; pool[o+2]=0xF0; pool[o+3]=0xFF; } /* red-ish */
        else if (x<2*W/3) { pool[o]=0x10; pool[o+1]=0xF0; pool[o+2]=0x20; pool[o+3]=0xFF; } /* green */
        else              { pool[o]=0xF0; pool[o+1]=0x20; pool[o+2]=0x10; pool[o+3]=0xFF; } /* blue */
    }
    printf("[wl] painted %dx%d pool @0x%lx, sending surface wire\n", W, H, (unsigned long)pool);

    unsigned char m[256]; int n = 0;
    /* 1. wl_display.get_registry(new_id=2) */
    wl32(m,0,1); m[4]=1; m[5]=0; m[6]=12; m[7]=0; wl32(m,8,2); n=12;
    /* 2. bind(new_id=3){name=2,"wl_shm",ver1}  obj=registry(2) */
    { int o=n; wl32(m,o+0,2); m[o+4]=0;m[o+5]=0; wl32(m,o+6,32); wl32(m,o+8,2); wl32(m,o+12,6); memcpy(m+o+16,"wl_shm",6); wl32(m,o+24,1); wl32(m,o+28,3); n=o+32; }
    /* 3. bind(new_id=4){name=1,"wl_compositor",ver4} */
    { int o=n; wl32(m,o+0,2); m[o+4]=0;m[o+5]=0; wl32(m,o+6,40); wl32(m,o+8,1); wl32(m,o+12,13); memcpy(m+o+16,"wl_compositor\0\0\0",16); wl32(m,o+32,4); wl32(m,o+36,4); n=o+40; }
    /* 4. wl_compositor.create_surface(new_id=5) obj=comp(4) */
    { int o=n; wl32(m,o+0,4); m[o+4]=0;m[o+5]=0; wl32(m,o+6,12); wl32(m,o+8,5); n=o+12; }
    /* 5. wl_shm.create_pool(new_id=6, fd=pool, size) obj=shm(3) */
    { int o=n; wl32(m,o+0,3); m[o+4]=0;m[o+5]=0; wl32(m,o+6,20); wl32(m,o+8,6); wl32(m,o+12,(unsigned)(unsigned long)pool); wl32(m,o+16,W*H*4); n=o+20; }
    /* 6. wl_shm_pool.create_buffer(new_id=7,0,W,H,stride,0) obj=pool(6) */
    { int o=n; wl32(m,o+0,6); m[o+4]=0;m[o+5]=0; wl32(m,o+6,32); wl32(m,o+8,7); wl32(m,o+12,0); wl32(m,o+16,W); wl32(m,o+20,H); wl32(m,o+24,W*4); wl32(m,o+28,0); n=o+32; }
    /* 7. wl_surface.attach(buffer=7,0,0) obj=surface(5) op1 */
    { int o=n; wl32(m,o+0,5); m[o+4]=1;m[o+5]=0; wl32(m,o+6,20); wl32(m,o+8,7); wl32(m,o+12,0); wl32(m,o+16,0); n=o+20; }
    /* 8. wl_surface.commit() obj=surface(5) op6 */
    { int o=n; wl32(m,o+0,5); m[o+4]=6;m[o+5]=0; wl32(m,o+6,8); n=o+8; }

    int r = (int)write(fd, m, n);
    printf("[wl] wrote %d bytes (surface attach+commit)\n", r);
    printf("[wl] DONE -- kernel compositor printed PRESENTED if blit ok\n");
    return 0;
}