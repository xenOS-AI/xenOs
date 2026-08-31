// xenOS file-backed mmap test (Phase D de-risking): mmap(fd, MAP_PRIVATE) of a real
// file off the ext4 rootfs returns the file's bytes in memory -- the exact mechanism
// ld-musl uses to map a DT_NEEDED shared library (.so) into a process. Bundled blob.
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

int main(void)
{
    say("[fmmap] file-backed mmap (.so mapping) test\n");

    int fd = open("/usr/lib/libwayland.so.0", O_RDONLY);
    if (fd < 0) { say("[fmmap] FAIL open\n"); _exit(1); }

    char *m = mmap(0, 4096, PROT_READ, MAP_PRIVATE, fd, 0);
    if (m == (void*)-1) { say("[fmmap] FAIL mmap\n"); _exit(1); }
    say((m[0] == 'l' && m[1] == 'i' && m[9] == 'd') ? "[fmmap] mapped .so bytes OK\n" : "[fmmap] MISMATCH\n");

    char b[24];
    int n = (int)read(fd, b, 24);
    int same = 1;
    for (int i = 0; i < 24; i++) { if (b[i] != m[i]) { same = 0; break; } }
    say((n == 24 && same) ? "[fmmap] mmap == read bytes OK\n" : "[fmmap] mmap != read\n");

    struct stat st;
    int s = fstat(fd, &st);
    say((s == 0 && st.st_size == 24) ? "[fmmap] fstat size 24 OK\n" : "[fmmap] fstat fail\n");
    say("[fmmap] DONE\n");
    _exit(0);
}