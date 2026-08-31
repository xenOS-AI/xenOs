// xenOS ioctl() dispatch (Phase A.5) test: TCGETS/TIOCGWINSZ on stdout + a
// framebuffer-screeninfo query that every real userspace (musl tty probing, and
// the upcoming compositor) performs. Bundled as the boot blob.
#include <unistd.h>
#include <sys/ioctl.h>
#include <termios.h>

static int slen(char *s) { int n = 0; while (s[n]) n++; return n; }
static void say(char *s) { write(1, s, slen(s)); }

struct fbs { unsigned int xres, yres, xres_virtual, yres_virtual, xoffset, yoffset, bits_per_pixel; };

int main(void)
{
    say("[ioctl] ioctl dispatch test\n");

    struct termios t;
    if (ioctl(1, TCGETS, &t) != 0) { say("[ioctl] FAIL TCGETS\n"); _exit(1); }
    say("[ioctl] TCGETS on stdout OK\n");

    unsigned short ws[4];
    if (ioctl(1, TIOCGWINSZ, &ws) != 0) { say("[ioctl] FAIL TIOCGWINSZ\n"); _exit(1); }
    say((ws[0] == 25 && ws[1] == 80) ? "[ioctl] TIOCGWINSZ 80x25 OK\n" : "[ioctl] TIOCGWINSZ mismatch\n");

    struct fbs f;
    if (ioctl(1, 0x4600, &f) != 0) { say("[ioctl] FAIL FBIOGET\n"); _exit(1); }
    say((f.xres > 0 && f.yres > 0 && f.bits_per_pixel == 32)
        ? "[ioctl] FBIOGET_VSCREENINFO xres/yres/32bpp OK\n"
        : "[ioctl] FBIO mismatch\n");

    if (ioctl(1, 0x9999, 0) != -1) { say("[ioctl] FAIL: unknown request not ENOTTY\n"); _exit(1); }
    say("[ioctl] unknown request -> ENOTTY OK\n");

    say("[ioctl] DONE\n");
    _exit(0);
}