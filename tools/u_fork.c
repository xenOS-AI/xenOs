// xenOS fork() test: exercises the SYSV disptach of SYS_fork + wait4 against a
// real musl binary. Bundled into the kernel as the Linux userland blob(s) so it
// runs at boot. Written with raw write(2) so output is unbuffered (no stdio
// buffering reorder across the fork), and _exit to skip atexit flushes.
#include <unistd.h>
#include <sys/wait.h>

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

int main(void)
{
    say("[fork] before fork, pid-clone test\n");
    pid_t pid = fork();
    if (pid == 0)
    {
        say("[fork] CHILD running\n");
        // child writes into stdio/heap; must NOT disturb the parent's copy
        char cbuf[64];
        cbuf[0] = (char)0x41;              // 'A', so we can spot child vs parent pages
        say("[fork] child exiting\n");
        _exit(0);
    }
    else if (pid > 0)
    {
        say("[fork] PARENT got child pid\n");
        int st = 0;
        pid_t r = waitpid(pid, &st, 0);
        (void)r;
        say("[fork] PARENT waitpid returned, child reaped\n");
        _exit(0);
    }
    else
    {
        say("[fork] fork() FAILED\n");
        _exit(1);
    }
}