// xenOS eventfd + epoll test (Phase D de-risking): the exact pattern wl_event_loop
// (wlroots/labwc) uses -- an epoll interest on an eventfd, armed by write(), wakes
// the loop, read() drains it, and the loop idles again. Bundled as the boot blob.
#include <unistd.h>
#include <sys/eventfd.h>
#include <sys/epoll.h>
#include <stdint.h>

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

int main(void)
{
    say("[evfd] eventfd + epoll (wl_event_loop) test\n");

    int efd = eventfd(0, 0);
    if (efd < 0) { say("[evfd] FAIL eventfd\n"); _exit(1); }
    int epf = epoll_create1(0);
    struct epoll_event ae;
    ae.events = EPOLLIN; ae.data.fd = efd;
    if (epoll_ctl(epf, EPOLL_CTL_ADD, efd, &ae) != 0) { say("[evfd] FAIL epoll_ctl\n"); _exit(1); }

    struct epoll_event r[4];
    int n = epoll_wait(epf, r, 4, 0);
    say(n == 0 ? "[evfd] not ready before signal OK\n" : "[evfd] FAIL early ready\n");

    uint64_t v = 0x100;
    if (write(efd, &v, 8) != 8) { say("[evfd] FAIL write\n"); _exit(1); }
    n = epoll_wait(epf, r, 4, 0);
    say(n == 1 && (r[0].events & EPOLLIN) ? "[evfd] epoll POLLIN after signal OK\n" : "[evfd] FAIL no wake\n");

    uint64_t c = 0;
    int rr = (int)read(efd, &c, 8);
    say(rr == 8 && c == 0x100 ? "[evfd] read value 0x100 OK\n" : "[evfd] FAIL read\n");

    n = epoll_wait(epf, r, 4, 0);
    say(n == 0 ? "[evfd] drained -> not ready OK\n" : "[evfd] FAIL re-ready\n");
    say("[evfd] DONE\n");
    _exit(0);
}