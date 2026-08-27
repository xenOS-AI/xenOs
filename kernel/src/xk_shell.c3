module xk;

// ============================================================================
// xenOS shell + tiny in-memory VFS. Output is rendered through the terminal
// (term_puts), which mirrors to the serial console for headless verification.
// ============================================================================

fn bool streq(char* a, char* b)
{
    while (*a != 0 && *a == *b) { a++; b++; }
    return *a == *b;
}

// copy the first whitespace-delimited token of `line` into `out` (max n-1 chars)
fn void next_tok(char* line, char* out, int n)
{
    int i = 0;
    while (line[i] != 0 && line[i] != ' ' && line[i] != '\t')
    {
        if (i < n - 1) { out[i] = line[i]; }
        i++;
    }
    if (i < n - 1) { out[i] = 0; } else { out[n - 1] = 0; }
}

// find the argument string that follows `cmd` in `line` (may be empty)
fn void skip_cmd(char* line, char* arg, int n)
{
    int i = 0;
    while (line[i] != 0 && line[i] != ' ') i++;
    while (line[i] == ' ') i++;
    int j = 0;
    while (line[i] != 0)
    {
        if (j < n - 1) { arg[j] = line[i]; }
        i++;
        j++;
    }
    if (j < n - 1) { arg[j] = 0; } else { arg[n - 1] = 0; }
}

// ---- tiny VFS: a fixed catalog of files ----
fn void vfs_ls()
{
    term_puts("  README  motd  release  version  /etc/motd\r\n");
}

fn void vfs_cat(char* name)
{
    if (streq(name, "README"))      { term_puts("xenOS: a from-scratch hobby OS written in C3.\r\n"); }
    else if (streq(name, "motd"))   { term_puts("Welcome to xenOS.\r\n"); }
    else if (streq(name, "release")){ term_puts("xenOS 0.1 (hand-written, C3)\r\n"); }
    else if (streq(name, "version")){ term_puts("kernel 0.1 - no external code\r\n"); }
    else if (streq(name, "/etc/motd")) { term_puts("Welcome to xenOS.\r\n"); }
    else
    {
        term_puts("cat: no such file: ");
        term_puts(name);
        term_puts("\r\n");
    }
}

// ---- built-in commands ----
fn void shell_help()
{
    term_puts("built-ins: help ls cat <file> echo <text> clear about uname ps sysc mem heap poweroff reboot\r\n");
}

fn void shell_about()
{
    term_puts("xenOS - a from-scratch hobby operating system\r\n");
    term_puts("bootloader/kernel/libc/gui all hand-written in C3+asm\r\n");
}

fn void shell_ps()
{
    term_puts("pid  name        state\r\n");
    for (int i = 0; i < MAX_TASKS; i++)
    {
        if (g_tasks[i].used)
        {
            term_puts("  ");
            term_putdec(g_tasks[i].pid);
            term_puts("   ");
            term_puts(&g_tasks[i].name[0]);
            term_puts("    running\r\n");
        }
    }
}

// run one command line
fn void shell_run(char* line)
{
    char[24] cmd;
    char[TERM_CW] arg;
    next_tok(line, &cmd[0], 24);
    skip_cmd(line, &arg[0], TERM_CW);

    if (cmd[0] == 0) { return; }
    else if (streq(&cmd[0], "help"))  { shell_help(); }
    else if (streq(&cmd[0], "ls"))    { vfs_ls(); }
    else if (streq(&cmd[0], "cat"))   { vfs_cat(&arg[0]); }
    else if (streq(&cmd[0], "echo"))  { term_puts(&arg[0]); term_puts("\r\n"); }
    else if (streq(&cmd[0], "about")) { shell_about(); }
    else if (streq(&cmd[0], "uname")) { term_puts("xenOS kernel 0.1 x86_64\r\n"); }
    else if (streq(&cmd[0], "ps"))    { shell_ps(); }
    else if (streq(&cmd[0], "clear")) { term_clear(); }
    else if (streq(&cmd[0], "mem"))
    {
        int total = (int)g_total_frames;
        int used  = (int)g_used_frames;
        term_puts("frame allocator (4 KiB):\r\n");
        term_puts("  total frames = "); term_putdec(total);
        term_puts("  used = "); term_putdec(used);
        term_puts("  free = "); term_putdec(total - used);
        term_puts("\r\n");
        ulong p = frame_alloc();
        term_puts("  alloc page @ "); term_puthex(p); term_puts("\r\n");
        if (p != 0)
        {
            ((char*)p)[0] = (char)0x5A;
            ((char*)p)[4095] = (char)0x5A;
            term_puts("  write/read-back byte0 = ");
            term_putdec((int)((char*)p)[0]);
            term_puts("\r\n");
            frame_free(p);
        }
        term_puts("  after free, used = "); term_putdec((int)g_used_frames); term_puts("\r\n");
    }
    else if (streq(&cmd[0], "poweroff")) { xk_shutdown(); }
    else if (streq(&cmd[0], "reboot"))   { xk_reboot(); }
    else if (streq(&cmd[0], "heap"))
    {
        term_puts("kernel heap: in use = "); term_putdec((int)heap_bytes_in_use); term_puts(" bytes\r\n");
        void* a = kmalloc(64);
        void* b = kmalloc(2048);
        void* c = kmalloc(4000);
        term_puts("  a@"); term_puthex((ulong)a);
        term_puts(" b@"); term_puthex((ulong)b);
        term_puts(" c@"); term_puthex((ulong)c);
        term_puts(" (in use "); term_putdec((int)heap_bytes_in_use); term_puts(")\r\n");
        if (a != null) { memset(a, (int)0xAB, 64);    term_puts("  a[63]="); term_putdec((int)((char*)a)[63]); }
        if (b != null) { memset(b, (int)0xCD, 2048);  term_puts("  b[2047]="); term_putdec((int)((char*)b)[2047]); }
        if (c != null) { memset(c, (int)0xEF, 4000);  term_puts("  c[3999]="); term_putdec((int)((char*)c)[3999]); }
        term_puts("\r\n");
        kfree(b); kfree(a); kfree(c);
        term_puts("  after free, in use = "); term_putdec((int)heap_bytes_in_use); term_puts("\r\n");
        void* d = kmalloc(100);
        term_puts("  realloc d@"); term_puthex((ulong)d); term_puts("\r\n");
        kfree(d);
    }
    else if (streq(&cmd[0], "sysc"))
    {
        term_puts("syscalls via INT 0x80:\r\n");
        term_puts("  getpid -> ");
        term_putdec(sys_getpid());
        term_puts("\r\n");
        sys_puts("  SYS_PUTS wrote this to serial\r\n");
        term_puts("  ticks  -> ");
        term_putdec((int)sys_ticks());
        term_puts("\r\n");
    }
    else
    {
        term_puts("sh: unknown command: ");
        term_puts(&cmd[0]);
        term_puts(" (type help)\r\n");
    }
}

fn void shell_banner()
{
    term_puts("xenOS 0.1 shell - type help\r\n");
}