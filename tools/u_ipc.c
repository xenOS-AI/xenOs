// xenOS concurrent cross-process IPC test (Phase A.1): a parent forks a child, and
// the two exchange bytes over an AF_UNIX socketpair while the scheduler parks/waits.
// This is the compositor<->client model: one process produces, the other consumes,
// blocking on read() and waitpid() while the other runs. Bundled as the boot blob.
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

int main(void)
{
    say("[ipc] fork+socketpair concurrent IPC test\n");
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { say("[ipc] socketpair FAILED\n"); _exit(1); }

    pid_t pid = fork();
    if (pid == 0)
    {
        /* CHILD: consume the bytes the PARENT will write (blocks until data) */
        char b[8];
        int n = (int)read(sv[0], b, 2);
        if (n == 2 && b[0] == 'H' && b[1] == 'I')
            say("[ipc] CHILD received 'HI' from PARENT via socket OK\n");
        else say("[ipc] CHILD read mismatch\n");

        /* and reply back */
        write(sv[0], "yo", 2);
        _exit(0);
    }
    else if (pid > 0)
    {
        /* PARENT: produce the bytes, then write */
        say("[ipc] PARENT forked child, writing to socket\n");
        write(sv[1], "HI", 2);
        /* now block waiting for the child */
        int st = 0;
        pid_t r = waitpid(pid, &st, 0);
        (void)r;
        say("[ipc] PARENT reaped child, IPC complete\n");
        _exit(0);
    }
    else { say("[ipc] fork FAILED\n"); _exit(1); }
}