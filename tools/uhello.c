/*
 * uhello.c - host-built POSIX test binary for xenOS's Linux userland.
 * This is the TARGET program xenOS loads and runs through its own ELF
 * loader + Linux syscall ABI. Built with musl, static, non-PIE, so it is
 * self-contained (no dynamic linker needed) and linked at a low vaddr that
 * xenOS's identity page tables can map.
 *
 * Build:  musl-gcc -static -no-pie -O2 -o build/uhello tools/uhello.c
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <fcntl.h>
#include <errno.h>

int main(int argc, char **argv)
{
    /* plain libc write path */
    puts("hello from a real musl binary in xenOS");

    /* identity / uname / cwd */
    printf("uid=%d gid=%d\n", (int)getuid(), (int)getgid());
    struct utsname u;
    if (!uname(&u)) printf("uname sysname=%s machine=%s\n", u.sysname, u.machine);
    char cwd[64];
    if (getcwd(cwd, sizeof(cwd))) printf("cwd=%s\n", cwd);

    /* getpid + clock_gettime (POSIX system calls) */
    pid_t pid = getpid();
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    printf("pid=%d mono=%lld.%09ld\n", (int)pid,
           (long long)ts.tv_sec, ts.tv_nsec);

    /* dynamic heap via malloc (exercises brk/mmap inside musl) */
    char *buf = malloc(65536);
    if (!buf) { perror("malloc"); return 2; }
    memset(buf, 'x', 64);
    buf[64] = 0;
    printf("heap=%s argc=%d\n", buf, argc);

    /* stat a real file on the FAT volume (POSIX stat -> fstatat -> kernel fills musl kstat) */
    struct stat st;
    if (stat("/MOTD.TXT", &st) == 0)
        printf("stat dev=%lx ino=%lx nlink=%lu mode=%o size=%ld\n",
               (unsigned long)st.st_dev, (unsigned long)st.st_ino,
               (unsigned long)st.st_nlink, st.st_mode, (long)st.st_size);
    else fprintf(stderr, "stat failed errno=%d\n", errno);

    /* open/read/close a real file on the FAT volume */
    int fd = open("/MOTD.TXT", O_RDONLY);
    if (fd >= 0) {
        char r[64];
        ssize_t n = read(fd, r, sizeof(r) - 1);
        if (n > 0) { r[n] = 0; printf("file=\"%s\"\n", r); }
        close(fd);
    } else {
        printf("open /MOTD.TXT failed errno=%d\n", errno);
    }

    puts("bye from xenOS userland");
    return 0;
}