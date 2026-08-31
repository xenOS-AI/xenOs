// xenOS in-guest ext4 rootfs read test (Phase C): an unprivileged musl process
// opens real files off the ext4 root filesystem (secondary IDE slave) that the
// kernel's xk_ext4.c3 driver reads -- including a nested /usr/lib path and a
// relative symlink. This is the read path a dynamic loader will use for .so libs.
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

int main(void)
{
    say("[ext4] in-guest ext4 rootfs read test\n");

    int fd = open("/usr/lib/libwayland.so.0", O_RDONLY);
    if (fd < 0) { say("[ext4] FAIL open /usr/lib/libwayland.so.0\n"); _exit(1); }
    char b[64];
    int n = (int)read(fd, b, 40);
    close(fd);
    say((n == 24 && b[0] == 'l' && b[2] == 'b' && b[9] == 'd')
        ? "[ext4] /usr/lib/libwayland.so.0 bytes OK\n" : "[ext4] libwayland MISMATCH\n");

    fd = open("/usr/lib/libwayland.so", O_RDONLY);   /* symlink -> libwayland.so.0 */
    if (fd < 0) { say("[ext4] FAIL symlink open\n"); _exit(1); }
    n = (int)read(fd, b, 40);
    close(fd);
    say((n == 24 && b[9] == 'd') ? "[ext4] symlink descends to target OK\n" : "[ext4] symlink MISMATCH\n");

    fd = open("/MOTD.TXT", O_RDONLY);                /* ext4 rootfs / */
    if (fd < 0) { say("[ext4] FAIL open /MOTD.TXT\n"); _exit(1); }
    n = (int)read(fd, b, 40);
    close(fd);
    say((n == 29 && b[0] == 'h' && b[25] == 'n') ? "[ext4] /MOTD.TXT from rootfs OK\n" : "[ext4] MOTD mismatch\n");

    struct stat st;
    int s = stat("/usr", &st);
    say((s == 0 && (st.st_mode & S_IFMT) == S_IFDIR) ? "[ext4] /usr is a dir OK\n" : "[ext4] stat /usr fail\n");

    say(open("/usr/lib/nope.so", O_RDONLY) < 0 ? "[ext4] absent -> ENOENT OK\n" : "[ext4] FAIL absent\n");
    say("[ext4] DONE\n");
    _exit(0);
}