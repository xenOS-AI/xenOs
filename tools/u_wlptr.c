// xenOS Phase D pointer: bind wl_seat, get_pointer, and receive a wl_pointer.motion
// event (fixed-point coords from the LIVE kernel mouse state) + a button event.
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>

static void wl32(unsigned char* m, int o, unsigned v){ m[o]=v&0xFF; m[o+1]=(v>>8)&0xFF; m[o+2]=(v>>16)&0xFF; m[o+3]=(v>>24)&0xFF; }

int main(void)
{
    setenv("XDG_RUNTIME_DIR", "/run", 1);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
    strncpy(a.sun_path, "/run/wayland-0", sizeof a.sun_path - 1);
    if (connect(fd, (struct sockaddr*)&a, sizeof a) != 0) { printf("[ptr] connect FAIL\n"); return 2; }

    unsigned char m[128]; int n = 0;
    wl32(m,0,1); m[4]=1; m[5]=0; m[6]=12; m[7]=0; wl32(m,8,2); n=12;            /* get_registry(2) */
    { int o=n; wl32(m,o+0,2); m[o+4]=0;m[o+5]=0; wl32(m,o+6,32); wl32(m,o+8,3); wl32(m,o+12,6); memcpy(m+o+16,"wl_seat",6); wl32(m,o+24,6); wl32(m,o+28,8); n=o+32; } /* bind seat id=8 */
    { int o=n; wl32(m,o+0,8); m[o+4]=2;m[o+5]=0; wl32(m,o+6,12); wl32(m,o+8,10); n=o+12; }            /* get_pointer(new_id=10) op2 */

    if (write(fd, m, n) != n) { printf("[ptr] write FAIL\n"); return 2; }
    unsigned char r[256]; int rn = (int)read(fd, r, 256);
    int i, motion_ok = 0, button_ok = 0; int mx = -1, my = -1;
    for (i = 0; i + 20 <= rn; i++)
    {
        unsigned obj = r[i]|(r[i+1]<<8)|(r[i+2]<<16)|(r[i+3]<<24);
        unsigned op  = r[i+4]|(r[i+5]<<8);
        if (obj == 10u && op == 0u) { /* motion */ mx = (int)((r[i+12]|(r[i+13]<<8)|(r[i+14]<<16)|(r[i+15]<<24))>>16);
                                       my = (int)((r[i+16]|(r[i+17]<<8)|(r[i+18]<<16)|(r[i+19]<<24))>>16); motion_ok = 1; }
        if (obj == 10u && op == 2u && i + 24 <= rn) { unsigned btn = r[i+16]|(r[i+17]<<8); button_ok = (btn == 0x110); }
    }
    printf("[ptr] motion x=%d y=%d button_ok=%d\n", mx, my, button_ok);
    printf(motion_ok && mx == 120 && my == 80 && button_ok ? "[ptr] POINTER OK (120,80 + left button)\n"
                                                              : "[ptr] POINTER FAIL\n");
    return (motion_ok && mx == 120 && my == 80 && button_ok) ? 0 : 1;
}