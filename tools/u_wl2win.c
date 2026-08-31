// xenOS Phase D window manager: present TWO independent wl_shm surface windows
// (red + blue) in one wire exchange; the compositor tiles them at different
// framebuffer offsets (win0 at top-left, win1 top-right).
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>

#define W 300
#define H 180
static void wl32(unsigned char* m, int o, unsigned v){ m[o]=v&0xFF; m[o+1]=(v>>8)&0xFF; m[o+2]=(v>>16)&0xFF; m[o+3]=(v>>24)&0xFF; }

int main(void)
{
    setenv("XDG_RUNTIME_DIR", "/run", 1);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
    strncpy(a.sun_path, "/run/wayland-0", sizeof a.sun_path - 1);
    if (connect(fd, (struct sockaddr*)&a, sizeof a) != 0) { printf("[wm] connect FAIL\n"); return 2; }

    unsigned char* ra = mmap(0, W*H*4, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_ANONYMOUS, -1, 0);
    unsigned char* rb = mmap(0, W*H*4, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_ANONYMOUS, -1, 0);
    if (ra == (void*)-1 || rb == (void*)-1) { printf("[wm] mmap FAIL\n"); return 2; }
    int x, y;
    for (y = 0; y < H; y++) for (x = 0; x < W; x++) { unsigned o=(y*W+x)*4; ra[o]=0x10; ra[o+1]=0x20; ra[o+2]=0xF0; ra[o+3]=0xFF; rb[o]=0xF0; rb[o+1]=0x20; rb[o+2]=0x10; rb[o+3]=0xFF; }
    printf("[wm] painted window A (red) @0x%lx and window B (blue) @0x%lx\n", (unsigned long)ra, (unsigned long)rb);

    unsigned char m[512]; int n = 0;
    wl32(m,0,1); m[4]=1;m[5]=0; m[6]=12;m[7]=0; wl32(m,8,2); n=12;                                   /* get_registry(2) */
    { int o=n; wl32(m,o+0,2); m[o+4]=0;m[o+5]=0; wl32(m,o+6,32); wl32(m,o+8,2); wl32(m,o+12,6); memcpy(m+o+16,"wl_shm",6); wl32(m,o+24,1); wl32(m,o+28,3); n=o+32; }   /* shm id=3 */
    { int o=n; wl32(m,o+0,2); m[o+4]=0;m[o+5]=0; wl32(m,o+6,40); wl32(m,o+8,1); wl32(m,o+12,13); memcpy(m+o+16,"wl_compositor\0\0\0",16); wl32(m,o+32,4); wl32(m,o+36,4); n=o+40; } /* comp id=4 */
    /* window A: create_surface(5), pool(6,ra), buffer(7), attach(7@5), commit(5) */
    { int o=n; wl32(m,o+0,4); m[o+4]=0;m[o+5]=0; wl32(m,o+6,12); wl32(m,o+8,5); n=o+12; }
    { int o=n; wl32(m,o+0,3); m[o+4]=0;m[o+5]=0; wl32(m,o+6,20); wl32(m,o+8,6); wl32(m,o+12,(unsigned)(unsigned long)ra); wl32(m,o+16,W*H*4); n=o+20; }
    { int o=n; wl32(m,o+0,6); m[o+4]=0;m[o+5]=0; wl32(m,o+6,32); wl32(m,o+8,7); wl32(m,o+12,0); wl32(m,o+16,W); wl32(m,o+20,H); wl32(m,o+24,W*4); wl32(m,o+28,0); n=o+32; }
    { int o=n; wl32(m,o+0,5); m[o+4]=1;m[o+5]=0; wl32(m,o+6,20); wl32(m,o+8,7); wl32(m,o+12,0); wl32(m,o+16,0); n=o+20; }
    { int o=n; wl32(m,o+0,5); m[o+4]=6;m[o+5]=0; wl32(m,o+6,8); n=o+8; }
    /* window B: create_surface(8), pool(9,rb), buffer(10), attach(10@8), commit(8) */
    { int o=n; wl32(m,o+0,4); m[o+4]=0;m[o+5]=0; wl32(m,o+6,12); wl32(m,o+8,8); n=o+12; }
    { int o=n; wl32(m,o+0,3); m[o+4]=0;m[o+5]=0; wl32(m,o+6,20); wl32(m,o+8,9); wl32(m,o+12,(unsigned)(unsigned long)rb); wl32(m,o+16,W*H*4); n=o+20; }
    { int o=n; wl32(m,o+0,9); m[o+4]=0;m[o+5]=0; wl32(m,o+6,32); wl32(m,o+8,10); wl32(m,o+12,0); wl32(m,o+16,W); wl32(m,o+20,H); wl32(m,o+24,W*4); wl32(m,o+28,0); n=o+32; }
    { int o=n; wl32(m,o+0,8); m[o+4]=1;m[o+5]=0; wl32(m,o+6,20); wl32(m,o+8,10); wl32(m,o+12,0); wl32(m,o+16,0); n=o+20; }
    { int o=n; wl32(m,o+0,8); m[o+4]=6;m[o+5]=0; wl32(m,o+6,8); n=o+8; }

    int r = (int)write(fd, m, n);
    printf("[wm] wrote %d bytes (2 windows)\n", r);
    printf("[wm] DONE -- compositor prints PRESENTED win0/win1 if both blitted\n");
    return 0;
}