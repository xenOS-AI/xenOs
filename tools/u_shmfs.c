// xenOS /dev/shm wl_shm pool test (Phase A.6): a process opens a /dev/shm pool,
// ftruncates it, mmap's it MAP_SHARED, writes pixels, forks; the child reads the
// parent's write and the parent reads the child's overwrite -- the shared-pool
// model Wayland clients use to share buffers with the compositor.
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/stat.h>

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

int main(void)
{
    say("[shmfs] wl_shm /dev/shm pool test\n");

    int fd = open("/dev/shm/pool", O_CREAT | O_RDWR, 0666);
    if (fd < 0) { say("[shmfs] FAIL open /dev/shm/pool\n"); _exit(1); }
    if (ftruncate(fd, 4096) != 0) { say("[shmfs] FAIL ftruncate\n"); _exit(1); }

    int *m = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == (void*)-1) { say("[shmfs] FAIL mmap pool\n"); _exit(1); }
    *m = 0x1234;
    say("[shmfs] pool mmap'ed MAP_SHARED, wrote 0x1234\n");

    pid_t pid = fork();
    if (pid == 0)
    {
        say(*m == 0x1234 ? "[shmfs] CHILD sees parent's pool write OK\n"
                          : "[shmfs] CHILD FAIL: pool not shared\n");
        *m = 0x9999;                 /* child writes into the shared pool */
        _exit(0);
    }
    else if (pid > 0)
    {
        int st = 0;
        waitpid(pid, &st, 0);
        say(*m == 0x9999 ? "[shmfs] PARENT sees child's pool write (shared) OK\n"
                          : "[shmfs] PARENT FAIL: pool not shared\n");
    }

    say(access("/dev/shm/pool", F_OK) == 0 ? "[shmfs] /dev/shm/pool exists OK\n" : "[shmfs] FAIL /dev/shm/pool\n");
    say(open("/dev/shm/nopool", O_RDONLY) < 0 ? "[shmfs] absent pool -> ENOENT OK\n" : "[shmfs] FAIL absent\n");
    say("[shmfs] DONE\n");
    _exit(0);
}