module mkfat;
// ============================================================================
// xenOS FAT16 data-volume builder — a freestanding HOST tool (no libc).
// Creates build/fat.img: an 8 MiB FAT16 partition (512B sectors, 1 sector per
// cluster, 1 reserved sector, 1 FAT of 64 sectors, 512 root entries) populated
// with a couple of real files. The kernel mounts it at boot via ATA PIO.
// Uses raw Linux syscalls via the asm helper lx_syscall (host_start.asm),
// exactly like mkdisk.c3.
// ============================================================================

const int O_WRONLY = 1;
const int O_CREAT  = 64;
const int O_TRUNC  = 512;
const long SEEK_END = 2;
const long SEEK_SET = 0;
const long SECTOR    = 512;
const long MODE_0666 = 438;   // 0o666

const long TOTAL_SECTORS  = 16384;   // 8 MiB
const long RESERVED       = 1;
const long NFATS          = 1;
const long FAT_SECTORS    = 64;
const long ROOT_ENTRIES   = 512;
const long ROOT_SECTORS   = 32;      // 512 * 32 / 512
const long DATA_START     = RESERVED + NFATS * FAT_SECTORS + ROOT_SECTORS; // 97
const long FAT_START      = RESERVED;
const long ROOT_START     = RESERVED + NFATS * FAT_SECTORS;

extern fn long lx_syscall(long n, long a, long b, long c, long d);

fn void* memset(void* dst, int val, ulong n) @export("memset")
{
    char* p = (char*)dst;
    for (ulong i = 0; i < n; i++) { p[i] = (char)val; }
    return dst;
}

fn long lx_open(char* p, long fl)  { return lx_syscall(2, (long)p, fl, MODE_0666, 0); }
fn long lx_write(long fd, char* b, long n){ return lx_syscall(1, fd, (long)b, n, 0); }
fn long lx_close(long fd)          { return lx_syscall(3, fd, 0, 0, 0); }
fn long lx_lseek(long fd, long o, long wh){ return lx_syscall(8, fd, o, wh, 0); }

fn void put_u16(char* b, long off, uint v){ b[off]=(char)(v&0xFF); b[off+1]=(char)((v>>8)&0xFF); }
fn void put_u32(char* b, long off, uint v){ b[off]=(char)(v&0xFF); b[off+1]=(char)((v>>8)&0xFF); b[off+2]=(char)((v>>16)&0xFF); b[off+3]=(char)((v>>24)&0xFF); }

// write an 8.3 short name into a dir entry (name padded to 8, ext padded to 3)
fn void put_name(char* b, char* name, char* ext)
{
    for (int i = 0; i < 11; i++) { b[i] = (char)' '; }
    for (int i = 0; i < 8 && name[i] != 0; i++) { b[i] = name[i]; }
    for (int i = 0; i < 3 && ext[i] != 0; i++) { b[8 + i] = ext[i]; }
}

fn int xk_host_main(int argc, char** argv) @export("xk_host_main")
{
    if (argc < 2)
    {
        lx_write(2, (char*)"usage: mkfat out.img [token]\n", 28);
        return 1;
    }
    // Optional 3rd arg = AI token (injected at build via $XENOS_AI_TOKEN; never
    // hard-coded/committed). Default stays a placeholder.
    char* token = (char*)"PLACEHOLDER_TOKEN_CHANGE_ME";
    if (argc > 2 && argv[2][0] != 0) { token = argv[2]; }
    long fd = lx_open(argv[1], O_WRONLY | O_CREAT | O_TRUNC);
    if (fd < 0) { lx_write(2, (char*)"mkfat: cannot open output\n", 27); return 1; }

    // create the (sparse) 8 MiB file, all zeros
    lx_lseek(fd, TOTAL_SECTORS * SECTOR - 1, SEEK_END);
    lx_write(fd, (char*)"\0", 1);

    // ---- boot sector (LBA 0) ----
    char[512] boot;
    memset(&boot[0], 0, 512);
    boot[0] = (char)0xEB; boot[1] = (char)0x3C; boot[2] = (char)0x90;   // jump
    char oemt = 'x'; // "xenOS" OEM identifier
    boot[3] = oemt; boot[4] = 'e'; boot[5] = 'n'; boot[6] = 'O'; boot[7] = 'S'; boot[8] = ' '; boot[9] = ' '; boot[10] = ' ';
    put_u16(&boot[0], 11, 512);        // bytes per sector
    boot[13] = (char)1;                // sectors per cluster
    put_u16(&boot[0], 14, (uint)RESERVED);
    boot[16] = (char)NFATS;
    put_u16(&boot[0], 17, (uint)ROOT_ENTRIES);
    put_u16(&boot[0], 19, (uint)TOTAL_SECTORS);       // total sectors 16-bit
    boot[21] = (char)0xF8;             // media
    put_u16(&boot[0], 22, (uint)FAT_SECTORS);          // FAT size (sectors)
    put_u16(&boot[0], 24, 1);          // sectors per track
    put_u16(&boot[0], 26, 1);          // heads
    boot[36] = (char)0x80;             // drive number
    boot[510] = (char)0x55; boot[511] = (char)0xAA;
    lx_lseek(fd, 0, SEEK_SET);
    lx_write(fd, &boot[0], 512);

    // ---- FAT (mark cluster 0,1; file clusters as end-of-chain) ----
    char[FAT_SECTORS * SECTOR] fat;
    memset(&fat[0], 0, FAT_SECTORS * SECTOR);
    put_u16(&fat[0], 0, 0xFFF8);       // media descriptor + end
    put_u16(&fat[0], 2, 0xFFFF);       // cluster 2 (MOTD) = end of chain
    put_u16(&fat[0], 4, 0xFFFF);       // cluster 3 (README) = end of chain
    put_u16(&fat[0], 6, 0xFFFF);       // cluster 4 (AI.CFG) = end of chain
    lx_lseek(fd, FAT_START * SECTOR, SEEK_SET);
    lx_write(fd, &fat[0], FAT_SECTORS * SECTOR);

    // ---- root directory: 512 entries, 3 files ----
    char[ROOT_SECTORS * SECTOR] root;
    memset(&root[0], 0, ROOT_SECTORS * SECTOR);
    // entry 0: MOTD.TXT, size 22 (bytes of "Welcome to xenOS.\r\n")
    put_name(&root[0], (char*)"MOTD", (char*)"TXT");
    root[11] = (char)0x20;             // archive
    put_u16(&root[0], 26, 2);          // first cluster
    put_u32(&root[0], 28, 22);         // size
    // entry 1: README.TXT
    put_name(&root[32], (char*)"README", (char*)"TXT");
    root[32 + 11] = (char)0x20;
    put_u16(&root[0], 26 + 32, 3);
    put_u32(&root[0], 28 + 32, 47);    // len("This file lives on the xenOS FAT16 disk.\r\n")
    // entry 2: AI.CFG - provider config (real OpenCode Go endpoint/model;
    //                    token injected at build, never hard-coded)
    char[1024] aicfg;
    uint alen = 0;
    char* cfg_model = (char*)"model=deepseek-v4-flash\n";
    char* cfg_ep    = (char*)"endpoint=https://opencode.ai/zen/go/v1/chat/completions\n";
    char* cfg_tok   = (char*)"token=";
    for (uint i = 0; cfg_model[i] != 0 && alen < 1023; i++) aicfg[alen++] = cfg_model[i];
    for (uint i = 0; cfg_ep[i] != 0 && alen < 1023; i++) aicfg[alen++] = cfg_ep[i];
    for (uint i = 0; cfg_tok[i] != 0 && alen < 1023; i++) aicfg[alen++] = cfg_tok[i];
    for (uint i = 0; token[i] != 0 && alen < 1023; i++) aicfg[alen++] = token[i];
    aicfg[alen++] = '\n';
    aicfg[alen] = 0;
    put_name(&root[64], (char*)"AI", (char*)"CFG");
    root[64 + 11] = (char)0x20;
    put_u16(&root[0], 26 + 64, 4);
    put_u32(&root[0], 28 + 64, alen);
    lx_lseek(fd, ROOT_START * SECTOR, SEEK_SET);
    lx_write(fd, &root[0], ROOT_SECTORS * SECTOR);

    // ---- file data at clusters 2, 3, 4 ----
    const char* MOTD = "Welcome to xenOS.\r\n";
    lx_lseek(fd, (DATA_START + 0) * SECTOR, SEEK_SET);
    lx_write(fd, (char*)MOTD, 22);
    const char* README = "This file lives on the xenOS FAT16 disk.\r\n";
    lx_lseek(fd, (DATA_START + 1) * SECTOR, SEEK_SET);
    lx_write(fd, (char*)README, 47);
    lx_lseek(fd, (DATA_START + 2) * SECTOR, SEEK_SET);
    lx_write(fd, &aicfg[0], alen);

    lx_close(fd);
    lx_write(2, (char*)"mkfat: wrote build/fat.img (8 MiB FAT16)\n", 41);
    return 0;
}