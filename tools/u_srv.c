// xenOS AF_UNIX named-server-socket test: socket/bind/listen/connect/accept
// (the Wayland display-socket model). A single process leads an endpoint, binds it
// to a pathname, listens, then connects to its own path and accepts; proves the
// accepted<->client pair round-trips bidirectionally. Bundled as the boot blob.
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

int main(void)
{
    say("[srv] AF_UNIX server socket test\n");
    struct sockaddr_un a;
    a.sun_family = AF_UNIX;
    strcpy(a.sun_path, "/tmp/xs");

    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) { say("[srv] socket FAILED\n"); _exit(1); }
    say("[srv] socket ok\n");

    if (bind(s, (struct sockaddr *)&a, (unsigned)sizeof(a)) != 0) { say("[srv] bind FAILED\n"); _exit(1); }
    if (listen(s, 4) != 0) { say("[srv] listen FAILED\n"); _exit(1); }
    say("[srv] bound+listening on /tmp/xs\n");

    int c = socket(AF_UNIX, SOCK_STREAM, 0);
    if (c < 0) { say("[srv] client socket FAILED\n"); _exit(1); }
    if (connect(c, (struct sockaddr *)&a, (unsigned)sizeof(a)) != 0) { say("[srv] connect FAILED\n"); _exit(1); }
    say("[srv] connect ok\n");

    int ac = accept(s, (struct sockaddr *)0, (socklen_t *)0);
    if (ac < 0) { say("[srv] accept FAILED\n"); _exit(1); }
    say("[srv] accept ok\n");

    /* client -> accepted */
    write(c, "hi-srv", 6);
    char b[64]; int r = (int)read(ac, b, (unsigned)sizeof(b));
    if (r == 6) { int ok = 1; for (int i = 0; i < 6; i++) if (b[i] != "hi-srv"[i]) ok = 0; say(ok ? "[srv] client->accepted OK\n" : "[srv] MISMATCH\n"); }
    else say("[srv] len mismatch\n");

    /* accepted -> client */
    write(ac, "reply", 5);
    int r2 = (int)read(c, b, (unsigned)sizeof(b));
    if (r2 == 5) { int ok = 1; for (int i = 0; i < 5; i++) if (b[i] != "reply"[i]) ok = 0; say(ok ? "[srv] accepted->client OK\n" : "[srv] reply MISMATCH\n"); }
    else say("[srv] reply len mismatch\n");

    say("[srv] DONE\n");
    _exit(0);
}