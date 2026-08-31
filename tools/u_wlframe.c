// xenOS Phase D: wl_surface.frame frame-callback. The client asks for a frame
// callback (new_id=12), commits a surface; the compositor emits wl_callback.done
// on that id -- the frame-pacing primitive animation clients use.
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
    if (connect(fd, (struct sockaddr*)&a, sizeof a) != 0) { printf("[fr] connect FAIL\n"); return 2; }
    unsigned char* p = mmap(0, W*H*4, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_ANONYMOUS, -1, 0);
    if (p == (void*)-1) { printf("[fr] mmap FAIL\n"); return 2; }
    int x, y; for (y=0;y<H;y++) for (x=0;x<W;x++){ unsigned o=(y*W+x)*4; p[o]=0x20;p[o+1]=0x60;p[o+2]=0xF0;p[o+3]=0xFF; }

    unsigned char m[256]; int n = 0;
    wl32(m,0,1); m[4]=1;m[5]=0; m[6]=12;m[7]=0; wl32(m,8,2); n=12;
    { int o=n; wl32(m,o+0,2); m[o+4]=0;m[o+5]=0; wl32(m,o+6,32); wl32(m,o+8,2); wl32(m,o+12,6); memcpy(m+o+16,"wl_shm",6); wl32(m,o+24,1); wl32(m,o+28,3); n=o+32; }
    { int o=n; wl32(m,o+0,2); m[o+4]=0;m[o+5]=0; wl32(m,o+6,40); wl32(m,o+8,1); wl32(m,o+12,13); memcpy(m+o+16,"wl_compositor\0\0\0",16); wl32(m,o+32,4); wl32(m,o+36,4); n=o+40; }
    { int o=n; wl32(m,o+0,4); m[o+4]=0;m[o+5]=0; wl32(m,o+6,12); wl32(m,o+8,5); n=o+12; }               /* create_surface(5) */
    { int o=n; wl32(m,o+0,3); m[o+4]=0;m[o+5]=0; wl32(m,o+6,20); wl32(m,o+8,6); wl32(m,o+12,(unsigned)(unsigned long)p); wl32(m,o+16,W*H*4); n=o+20; }
    { int o=n; wl32(m,o+0,6); m[o+4]=0;m[o+5]=0; wl32(m,o+6,32); wl32(m,o+8,7); wl32(m,o+12,0); wl32(m,o+16,W); wl32(m,o+20,H); wl32(m,o+24,W*4); wl32(m,o+28,0); n=o+32; }
    { int o=n; wl32(m,o+0,5); m[o+4]=1;m[o+5]=0; wl32(m,o+6,20); wl32(m,o+8,7); wl32(m,o+12,0); wl32(m,o+16,0); n=o+20; }   /* attach(7@5) */
    { int o=n; wl32(m,o+0,5); m[o+4]=3;m[o+5]=0; wl32(m,o+6,12); wl32(m,o+8,12); n=o+12; }              /* frame(new_id=12) op3 */
    { int o=n; wl32(m,o+0,5); m[o+4]=6;m[o+5]=0; wl32(m,o+6,8); n=o+8; }                                 /* commit op6 */

    if (write(fd, m, n) != n) { printf("[fr] write FAIL\n"); return 2; }
    unsigned char r[256]; int rn = (int)read(fd, r, 256);
    int i, got = 0; unsigned serial = 0;
    for (i = 0; i + 12 <= rn; i++)
    {
        unsigned obj = r[i]|(r[i+1]<<8)|(r[i+2]<<16)|(r[i+3]<<24);
        unsigned op  = r[i+4]|(r[i+5]<<8);
        if (obj == 12u && op == 0u) { serial = r[i+8]|(r[i+9]<<8)|(r[i+10]<<16)|(r[i+11]<<24); got = 1; }
    }
    printf("[fr] got wl_callback.done on frame id=%u serial=%u\n", 12u, serial);
    printf(got ? "[fr] FRAME OK (frame callback delivered)\n" : "[fr] FRAME FAIL\n");
    return got ? 0 : 1;
}