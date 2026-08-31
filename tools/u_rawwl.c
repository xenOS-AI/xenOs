// Raw unix-socket round trip to the KERNEL Wayland compositor (no libwayland):
// isolates the kernel socket+compositor path. Sends a wl_display.get_registry
// message and reads the wl_registry.global replies the kernel emits.
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
int main(void)
{
    setenv("XDG_RUNTIME_DIR", "/run", 1);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    printf("[raw] socket fd=%d\n", fd);
    struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
    strncpy(a.sun_path, "/run/wayland-0", sizeof a.sun_path - 1);
    int rc = connect(fd, (struct sockaddr*)&a, sizeof a);
    printf("[raw] connect rc=%d\n", rc);
    char m[12] = {0};         // wl_display.get_registry(new_id=2)
    m[0] = 1;                 // object id 1 (wl_display)
    m[4] = 1;                 // opcode get_registry
    m[6] = 12;                // size 12 (8 hdr + 4 new_id)
    m[8] = 2;                 // new_id = 2
    rc = (int)write(fd, m, 12);
    printf("[raw] write rc=%d\n", rc);
    char b[64];
    int n = (int)read(fd, b, 64);
    printf("[raw] read rc=%d\n", n);
    /* search for the interface strings the kernel advertised */
    int cp = 0, sp = 0, i, j;
    const char* comp = "wl_compositor"; int cl = 13;
    const char* shm  = "wl_shm";       int sl = 6;
    for (i = 0; i < n - cl + 1 && !cp; i++) { int ok = 1; for (j = 0; j < cl; j++) if (b[i + j] != comp[j]) { ok = 0; break; } if (ok) cp = 1; }
    for (i = 0; i < n - sl + 1 && !sp; i++) { int ok = 1; for (j = 0; j < sl; j++) if (b[i + j] != shm[j]) { ok = 0; break; } if (ok) sp = 1; }
    if (n >= 24 && cp && sp)
    {
        printf("[wl] KERNEL COMPOSITOR INTEROP OK: got wl_registry.global(wl_compositor) and (wl_shm)\n");
        return 0;
    }
    printf("[wl] INTEROP FAIL (bytes=%d comp=%d shm=%d)\n", n, cp, sp);
    return 1;
}