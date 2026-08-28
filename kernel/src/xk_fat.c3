module xk;

// ============================================================================
// xenOS FAT16 reader. Mounts the FAT16 data volume (build/fat.img) that the
// host tool tools/mkfat.c3 creates, and lets the shell list/read real files
// off the disk via the ATA PIO driver. This replaces the old hardcoded catalog
// with a genuine on-disk filesystem.
// Volume geometry (see tools/mkfat.c3): 512B sectors, 1 sector/cluster,
// 1 reserved sector, 1 FAT of FAT_SECTORS sectors, 512 root entries.
// ============================================================================

const uint FAT_SECTOR = 512;
const uint FAT_BASE   = ATA_BASE_SECONDARY;   // secondary IDE channel master
const uint FAT_DRIVE  = ATA_DRIVE_MASTER;

const uint FAT_SPC         = 1;    // sectors per cluster
const uint FAT_RESERVED    = 1;
const uint FAT_NFATS       = 1;
const uint FAT_ROOT_ENTRIES = 512;
const uint FAT_SECTORS     = 64;   // FAT size in sectors (matches mkfat.c3)
const uint FAT_ROOT_SECTORS = (FAT_ROOT_ENTRIES * 32 + 511) / 512;   // 32
const uint FAT_DATA_START   = FAT_RESERVED + FAT_NFATS * FAT_SECTORS + FAT_ROOT_SECTORS;
const uint FAT_ROOT_START   = FAT_RESERVED + FAT_NFATS * FAT_SECTORS;

bool g_fat_mounted;

// Single-character output to the terminal (term_puts takes a NUL-terminated string).
fn void fat_putc(char c)
{
    char[2] b;
    b[0] = c;
    b[1] = 0;
    term_puts(&b[0]);
}

// Read the FAT16 value (u16 LE) for cluster `cl`. Returns 0 ok.
fn int fat_get_cluster(uint cl, uint* val)
{
    ulong fat_byte = (ulong)cl * 2;
    uint sector = FAT_RESERVED + (uint)(fat_byte / FAT_SECTOR);
    uint off = (uint)(fat_byte % FAT_SECTOR);
    char[FAT_SECTOR] sec;
    if (ata_read_sectors(FAT_BASE, FAT_DRIVE, sector, 1, &sec[0]) != 0) return -1;
    *val = (uint)sec[off] | ((uint)((char)sec[off + 1]) << 8);
    return 0;
}

// Case-insensitive match: is `arg` a prefix of the 8.3 stored short name?
// The matching stops at the first stored padding space, so "motd" -> "MOTD"
// matches the entry stored as "MOTD     TXT" (we only compare the first N
// characters, where N = length("motd"), which are the name itself).
fn bool fatname_match(char* stored8_3, char* arg)
{
    int j = 0;
    while (arg[j] != 0)
    {
        char ac = arg[j];
        if (ac >= 'a' && ac <= 'z') { ac = (char)(ac - 'a' + 'A'); }   // uppercase arg
        if ((char)stored8_3[j] == (char)0x20) return false;             // arg longer than the real name
        if ((char)stored8_3[j] != ac) return false;
        j++;
    }
    return true;
}

// Read the whole file matched by `arg` into buf (capacity `cap`), setting *outlen.
// Returns 0 ok, 1 not found, -1 I/O error.
fn int fat_read_file(char* arg, char* buf, uint cap, uint* outlen)
{
    char[FAT_SECTOR] sec;
    for (uint r = 0; r < FAT_ROOT_SECTORS; r++)
    {
        if (ata_read_sectors(FAT_BASE, FAT_DRIVE, (ulong)FAT_ROOT_START + (ulong)r, 1, &sec[0]) != 0) return -1;
        for (int e = 0; e < 16; e++)
        {
            char* en = &sec[e * 32];
            if ((int)((char)en[0]) == 0) return 1;              // end of directory
            if ((int)((char)en[0]) == 0xE5) continue;           // deleted entry
            if (((int)((char)en[11]) & 0x08) != 0) continue;    // volume label / dir
            if (fatname_match(&en[0], arg))
            {
                uint cl = (uint)((int)((char)en[26]) & 0xFF) | ((uint)((int)((char)en[27]) & 0xFF) << 8);
                uint pos = 0;
                while (cl >= 2 && cl < 0xFFF8 && pos < cap)
                {
                    ulong first = (ulong)FAT_DATA_START + (ulong)(cl - 2) * FAT_SPC;
                    for (uint k = 0; k < FAT_SPC && pos < cap; k++)
                    {
                        char[FAT_SECTOR] dsec;
                        if (ata_read_sectors(FAT_BASE, FAT_DRIVE, first + (ulong)k, 1, &dsec[0]) != 0) return -1;
                        for (int b = 0; b < 512 && pos < cap; b++)
                        {
                            buf[pos++] = dsec[b];
                        }
                    }
                    uint next;
                    if (fat_get_cluster(cl, &next) != 0) return -1;
                    cl = next;
                }
                *outlen = pos;
                return 0;
            }
        }
    }
    return 1;
}

// List every regular file in the root directory onto the terminal.
fn void fat_list()
{
    char[FAT_SECTOR] sec;
    bool found_any = false;
    for (uint r = 0; r < FAT_ROOT_SECTORS; r++)
    {
        if (ata_read_sectors(FAT_BASE, FAT_DRIVE, (ulong)FAT_ROOT_START + (ulong)r, 1, &sec[0]) != 0)
        {
            term_puts("fat: read error\r\n");
            return;
        }
        for (int e = 0; e < 16; e++)
        {
            char* en = &sec[e * 32];
            if ((int)((char)en[0]) == 0) return;               // end
            if ((int)((char)en[0]) == 0xE5) continue;
            if (((int)((char)en[11]) & 0x08) != 0) continue;   // skip attr
            // print 8.3 trimmed
            term_puts("  ");
            for (int n = 0; n < 8; n++)
            {
                if ((char)en[n] == (char)0x20) break;
                fat_putc((char)en[n]);
            }
            term_puts(".");
            for (int n = 8; n < 11; n++)
            {
                if ((char)en[n] == (char)0x20) break;
                fat_putc((char)en[n]);
            }
            term_puts("\r\n");
            found_any = true;
        }
    }
    if (!found_any) term_puts("  (empty)\r\n");
}

// Mount the FAT16 volume and report it.
fn void fat_mount()
{
    g_fat_mounted = false;
    char[FAT_SECTOR] sec;
    if (ata_read_sectors(FAT_BASE, FAT_DRIVE, 0, 1, &sec[0]) != 0)
    {
        xk_puts("[fat] mount FAILED (no data disk?)\r\n");
        return;
    }
    // sanity: bytes per sector == 512 (offset 11-12) and 0x55AA signature
    uint bps = (uint)((char)sec[11]) | ((uint)((char)sec[12]) << 8);
    if (bps != 512 || ((int)((char)sec[510])) != 0x55 || ((int)((char)sec[511])) != 0xAA)
    {
        xk_puts("[fat] mount FAILED (bad BPB/signature)\r\n");
        return;
    }
    g_fat_mounted = true;
    xk_puts("[fat] mounted FAT16 data volume (8 MiB) via ATA PIO\r\n");
}