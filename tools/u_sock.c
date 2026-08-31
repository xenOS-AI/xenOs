// xenOS AF_UNIX socketpair test: exercises syscall 53 (socketpair) + read/write
// across the paired descriptors against a real musl binary. Bundled as the boot
// Linux userland blob. A single process proves the in-kernel byte-stream socket
// transport (the future Wayland IPC backbone).
#include <unistd.h>
#include <sys/socket.h>
#include <errno.h>

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

int main(void)
{
    say("[sock] socketpair test\n");
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { say("[sock] socketpair FAILED\n"); _exit(1); }
    say("[sock] socketpair ok, fds\n");

    char msg[] = "hello-xenos-socket";
    int n = (int)write(sv[0], msg, (unsigned)slen(msg));

    char rbuf[128];
    int r = (int)read(sv[1], rbuf, (unsigned)sizeof(rbuf));
    if (r == n)
    {
        int ok = 1;
        for (int i = 0; i < r; i++) if (rbuf[i] != msg[i]) ok = 0;
        say(ok ? "[sock] roundtrip OK\n" : "[sock] BYTES MISMATCH\n");
    }
    else
    {
        say("[sock] length mismatch\n");
    }

    // close fd0 then write to fd0: the peer should see EPIPE
    close(sv[0]);
    errno = 0;
    int e = (int)write(sv[1], "x", 1);
    say(e < 0 ? "[sock] EPIPE on closed peer OK\n" : "[sock] peer-write did NOT fail\n");
    _exit(0);
}