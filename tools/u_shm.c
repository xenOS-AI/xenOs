// xenOS MAP_SHARED cross-process shared memory test (Phase A.5): a parent maps a
// shared anonymous region, writes a value, forks; the child reads the parent's
// write, overwrites it, and the parent sees the child's write afterward -- proving
// the two processes point at the SAME physical frames (the wl_shm foundation).
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

int main(void)
{
    say("[shm] MAP_SHARED cross-process shared memory test\n");

    int *p = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (p == (void*)-1) { say("[shm] FAIL mmap MAP_SHARED\n"); _exit(1); }
    *p = 0x1234;
    say("[shm] mmap'ed shared region, wrote 0x1234\n");

    pid_t pid = fork();
    if (pid == 0)
    {
        if (*p == 0x1234) say("[shm] CHILD sees parent's write via shared page OK\n");
        else say("[shm] CHILD FAIL: shared not visible\n");
        *p = 0x9999;            /* child overwrites the shared page */
        _exit(0);
    }
    else if (pid > 0)
    {
        int st = 0;
        waitpid(pid, &st, 0);
        say(*p == 0x9999 ? "[shm] PARENT sees child's overwrite (shared) OK\n"
                          : "[shm] PARENT FAIL: did not share\n");
        _exit(0);
    }
    say("[shm] FAIL fork\n");
    _exit(1);
}