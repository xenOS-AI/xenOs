// xenOS minimal virtual filesystem (Phase A.6) test: /dev/null, /dev/zero,
// /proc stub files, and virtual directories (/dev/shm, /run). Bundled as the boot
// blob. Exercises open/read/write/stat/access on the devfs surface a compositor /
// Mesa / GTK will rely on.
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

int main(void)
{
    say("[vfs] virtual filesystem test\n");

    /* /dev/null: write discarded */
    int fd = open("/dev/null", O_WRONLY);
    if (fd < 0) { say("[vfs] FAIL open /dev/null\n"); _exit(1); }
    int w = (int)write(fd, "x", 1);
    close(fd);
    say(w == 1 ? "[vfs] /dev/null write discarded OK\n" : "[vfs] FAIL null write\n");

    /* /dev/zero: reads NULs */
    fd = open("/dev/zero", O_RDONLY);
    if (fd < 0) { say("[vfs] FAIL open /dev/zero\n"); _exit(1); }
    char zb[4];
    int n = (int)read(fd, zb, 4);
    close(fd);
    say((n == 4 && zb[0] == 0 && zb[3] == 0) ? "[vfs] /dev/zero NULs OK\n" : "[vfs] FAIL zero\n");

    /* /proc/version: a stub text file */
    fd = open("/proc/version", O_RDONLY);
    if (fd < 0) { say("[vfs] FAIL open /proc/version\n"); _exit(1); }
    char vb[64];
    int vn = (int)read(fd, vb, 63);
    close(fd);
    say((vn > 0) ? "[vfs] /proc/version readable OK\n" : "[vfs] FAIL proc read\n");

    /* stat /dev/null */
    struct stat st;
    int s = stat("/dev/null", &st);
    say(s == 0 ? "[vfs] stat /dev/null OK\n" : "[vfs] FAIL stat null\n");

    /* access on virtual dirs */
    say(access("/dev/shm", F_OK) == 0 ? "[vfs] access /dev/shm OK\n" : "[vfs] FAIL /dev/shm\n");
    say(access("/run", F_OK) == 0 ? "[vfs] access /run OK\n" : "[vfs] FAIL /run\n");
    say(access("/dev/dri", F_OK) != 0 ? "[vfs] access /dev/dri (absent) ENOENT OK\n" : "[vfs] FAIL /dev/dri present\n");

    say("[vfs] DONE\n");
    _exit(0);
}