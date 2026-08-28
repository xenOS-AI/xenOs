module xk;

// ============================================================================
// xenOS ATA PIO driver (polling IDE bus). The kernel reads the FAT16 data
// volume (build/fat.img) from the SECONDARY IDE channel master (base 0x170);
// the primary channel carries the boot disk (stage2 already reads it at 0x1F0).
// ============================================================================

const uint ATA_BASE_PRIMARY   = 0x1F0;
const uint ATA_BASE_SECONDARY = 0x170;
const uint ATA_DRIVE_MASTER   = 0x00;   // high nibble of bytes 6
const uint ATA_DRIVE_SLAVE    = 0x10;

// xk_pause / xk_inb / xk_outb are module-level externs (xk_core.c3).
extern fn ushort xk_inw(uint port);

// Wait until the drive is not busy (BSY clear). Returns 0 when ready, -1 if it
// hangs (defensive; a working drive clears bus within milliseconds).
fn int ata_wait_ready(uint base)
{
    for (int i = 0; i < 100000; i++)
    {
        if (((int)xk_inb((uint)(base + 7)) & 0x80) == 0) return 0;
        xk_pause();
    }
    return -1;
}

// Wait until the drive asserts DRQ (data request). Returns 0 ready, -1 error.
fn int ata_wait_drq(uint base)
{
    for (int i = 0; i < 100000; i++)
    {
        int st = (int)xk_inb((uint)(base + 7));
        if ((st & 0x80) == 0 && (st & 0x08) != 0) return 0;   // not busy + DRQ
        if ((st & 0x01) != 0) return -1;                       // ERR
        xk_pause();
    }
    return -1;
}

// Read `count` 512-byte sectors starting at LBA into buf, using 28-bit LBA PIO
// from drive (master/slave) on `base`. Returns 0 ok, non-zero on error.
fn int ata_read_sectors(uint base, uint drive_sel, ulong lba, uint count, char* buf)
{
    for (uint s = 0; s < count; s++)
    {
        ulong clba = lba + s;
        uint drive_head = 0xE0 | drive_sel | (uint)((clba >> 24) & 0x0F);
        if (ata_wait_ready(base) != 0) return -1;
        xk_outb((uint)(base + 6), (char)drive_head);        // drive + LBA bits 24-27
        xk_outb((uint)(base + 2), (char)1);                 // sector count = 1
        xk_outb((uint)(base + 3), (char)(clba & 0xFF));     // LBA 0-7
        xk_outb((uint)(base + 4), (char)((clba >> 8) & 0xFF));   // LBA 8-15
        xk_outb((uint)(base + 5), (char)((clba >> 16) & 0xFF));  // LBA 16-23
        xk_outb((uint)(base + 7), (char)0x20);              // READ SECTORS
        if (ata_wait_drq(base) != 0) return -1;
        // read 256 16-bit words from the data register
        for (int i = 0; i < 256; i++)
        {
            ushort w = xk_inw((uint)(base + 0));
            char* p = buf + (ulong)s * 512 + (ulong)i * 2;
            p[0] = (char)(w & 0xFF);
            p[1] = (char)((w >> 8) & 0xFF);
        }
    }
    return 0;
}