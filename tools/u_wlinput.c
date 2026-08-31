// xenOS Phase D input: a client binds wl_seat, requests a keyboard, and receives
// wl_keyboard.key (down/up) events from the kernel compositor over the real wire.
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
    if (connect(fd, (struct sockaddr*)&a, sizeof a) != 0) { printf("[in] connect FAIL\n"); return 2; }

    unsigned char m[256]; int n = 0;
    /* get_registry(new_id=2) */
    wl32(m,0,1); m[4]=1; m[5]=0; m[6]=12; m[7]=0; wl32(m,8,2); n=12;
    /* bind(new_id=8){name=3,"wl_seat",ver6} */
    { int o=n; wl32(m,o+0,2); m[o+4]=0;m[o+5]=0; wl32(m,o+6,32); wl32(m,o+8,3); wl32(m,o+12,6); memcpy(m+o+16,"wl_seat",6); wl32(m,o+24,6); wl32(m,o+28,8); n=o+32; }
    /* wl_seat.get_keyboard(new_id=9) obj=seat(8) op1 */
    { int o=n; wl32(m,o+0,8); m[o+4]=1;m[o+5]=0; wl32(m,o+6,12); wl32(m,o+8,9); n=o+12; }

    if (write(fd, m, n) != n) { printf("[in] write FAIL\n"); return 2; }
    unsigned char r[256]; int rn = (int)read(fd, r, 256);
    /* find a wl_keyboard.key event: object==9, opcode==4 */
    int i, got_down = 0, got_up = 0;
    for (i = 0; i + 24 <= rn; i++)
    {
        unsigned obj = r[i] | (r[i+1]<<8) | (r[i+2]<<16) | (r[i+3]<<24);
        unsigned op  = r[i+4] | (r[i+5]<<8);
        if (obj == 9u && op == 4u)
        {
            unsigned key = r[i+16]|(r[i+17]<<8)|(r[i+18]<<16)|(r[i+19]<<24);
            unsigned st  = r[i+20]|(r[i+21]<<8)|(r[i+22]<<16)|(r[i+23]<<24);
            printf("[in] wl_keyboard.key key=%u state=%s\n", key, st ? "DOWN" : "UP");
            if (key == 30u && st) got_down = 1;
            if (key == 30u && !st) got_up = 1;
        }
    }
    printf(got_down && got_up ? "[in] INPUT OK (key 30 down+up via wl_keyboard)\n"
                              : "[in] INPUT FAIL (read=%d)\n", rn);
    return (got_down && got_up) ? 0 : 1;
}