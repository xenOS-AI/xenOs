// xenOS poll()/ppoll test on the AF_UNIX socket layer: watch a listener not-ready,
// become POLLIN ready after a self-connect, plus POLLOUT on the client and POLLIN
// on an accepted endpoint with data waiting. Bundled as the boot blob.
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
#include <string.h>

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

int main(void)
{
    say("[poll] poll test\n");
    struct sockaddr_un a;
    a.sun_family = AF_UNIX;
    strcpy(a.sun_path, "/tmp/pp");

    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0 || bind(s, (struct sockaddr *)&a, (unsigned)sizeof(a)) != 0 || listen(s, 4) != 0)
    { say("[poll] setup FAILED\n"); _exit(1); }

    struct pollfd p[1];
    p[0].fd = s; p[0].events = POLLIN; p[0].revents = 0;
    int r0 = poll(p, 1, 0);
    say(r0 == 0 ? "[poll] listener not-ready before connect (0) OK\n" : "[poll] UNEXPECTED early ready\n");

    int c = socket(AF_UNIX, SOCK_STREAM, 0);
    if (c < 0 || connect(c, (struct sockaddr *)&a, (unsigned)sizeof(a)) != 0) { say("[poll] connect FAILED\n"); _exit(1); }

    p[0].revents = 0;
    int r1 = poll(p, 1, 0);
    say((r1 == 1 && (p[0].revents & POLLIN)) ? "[poll] listener POLLIN ready after connect OK\n" : "[poll] FAIL: no ready after connect\n");

    struct pollfd q[1];
    q[0].fd = c; q[0].events = POLLOUT; q[0].revents = 0;
    int r2 = poll(q, 1, 0);
    say((r2 == 1 && (q[0].revents & POLLOUT)) ? "[poll] client POLLOUT OK\n" : "[poll] FAIL: client not writable\n");

    write(c, "x", 1);
    int ac = accept(s, (struct sockaddr *)0, (socklen_t *)0);
    struct pollfd w[1];
    w[0].fd = ac; w[0].events = POLLIN; w[0].revents = 0;
    int r3 = poll(w, 1, 0);
    say((r3 == 1 && (w[0].revents & POLLIN)) ? "[poll] accepted POLLIN (data waiting) OK\n" : "[poll] FAIL: accepted not readable\n");

    say("[poll] DONE\n");
    _exit(0);
}