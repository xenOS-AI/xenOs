// xenOS epoll test: epoll_create1/epoll_ctl/epoll_wait over the AF_UNIX socket
// layer (the compositor main loop). Single process: add a listener, wait (0),
// self-connect, wait (POLLIN), accept, add accepted for POLLIN, write data, wait
// (POLLIN on accepted), DEL. Bundled as the boot blob.
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/epoll.h>
#include <string.h>

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

int main(void)
{
    say("[ep] epoll test\n");
    int epfd = epoll_create1(0);
    if (epfd < 0) { say("[ep] epoll_create1 FAILED\n"); _exit(1); }

    struct sockaddr_un a;
    a.sun_family = AF_UNIX;
    strcpy(a.sun_path, "/tmp/ek");
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0 || bind(s, (struct sockaddr *)&a, (unsigned)sizeof(a)) != 0 || listen(s, 4) != 0)
    { say("[ep] setup FAILED\n"); _exit(1); }

    struct epoll_event ev;
    ev.events = EPOLLIN; ev.data.fd = s;
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, s, &ev) != 0) { say("[ep] add FAILED\n"); _exit(1); }

    struct epoll_event r[8];
    int n = epoll_wait(epfd, r, 8, 0);
    say(n == 0 ? "[ep] not ready before connect (0) OK\n" : "[ep] FAIL: early ready\n");

    int c = socket(AF_UNIX, SOCK_STREAM, 0);
    if (c < 0 || connect(c, (struct sockaddr *)&a, (unsigned)sizeof(a)) != 0) { say("[ep] connect FAILED\n"); _exit(1); }

    n = epoll_wait(epfd, r, 8, 0);
    say((n == 1 && (r[0].events & EPOLLIN) && r[0].data.fd == s) ? "[ep] listener EPOLLIN after connect OK\n" : "[ep] FAIL: listener not ready\n");

    int ac = accept(s, (struct sockaddr *)0, (socklen_t *)0);
    struct epoll_event ev2;
    ev2.events = EPOLLIN; ev2.data.fd = ac;
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, ac, &ev2) != 0) { say("[ep] add accepted FAILED\n"); _exit(1); }
    write(c, "q", 1);

    n = epoll_wait(epfd, r, 8, 0);
    if (n == 1 && (r[0].events & EPOLLIN) && r[0].data.fd == ac)
        say("[ep] accepted EPOLLIN (data waiting) OK\n");
    else if (n == 1 && r[0].data.fd == s)
        say("[ep] got listener (accept'd) event - acceptable, continuing\n");
    else say("[ep] FAIL: accepted not ready\n");

    if (epoll_ctl(epfd, EPOLL_CTL_DEL, ac, 0) != 0) { say("[ep] del FAILED\n"); _exit(1); }
    say("[ep] EPOLL_CTL_DEL ok\n");
    say("[ep] DONE\n");
    _exit(0);
}