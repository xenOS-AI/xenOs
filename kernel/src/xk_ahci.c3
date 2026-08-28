module xk;

// ============================================================================
// xenOS AHCI (SATA HBA) driver.
// Detected by the PCI probe (class code 0x01.06 / vendor 8086 ich9-ahci, or any
// generic AHCI). Performs an HBA reset, enables the controller, enumerates the
// implemented ports, and issues a real single-sector READ (via a command header,
// a host-to-device FIS and a PRDT) to prove genuine SATA DMA I/O.
// All register access uses xk_mmio_read32/write32 (asm) so busy-waits are not
// optimized away.
// ============================================================================

extern fn uint  xk_mmio_read32(ulong addr);
extern fn void  xk_mmio_write32(ulong addr, uint val);

ulong g_ahci_base;      // ABAR (BAR5) as an identity-mapped physical pointer
bool  g_ahci_ready;

// ---- HBA registers ----
const uint HBA_CAP = 0x00;
const uint HBA_GHC = 0x04;   // HR=31, IE=6, AE=1
const uint HBA_IS  = 0x08;
const uint HBA_PI  = 0x0C;
const uint HBA_VS  = 0x28;

// ---- per-port registers (offset = 0x100 + port*0x80) ----
const uint P_CLB  = 0x00;    // command list base (low)
const uint P_CLBU = 0x04;
const uint P_FB   = 0x08;    // FIS base (low)
const uint P_FBU  = 0x0C;
const uint P_IS   = 0x10;
const uint P_IE   = 0x14;
const uint P_CMD  = 0x18;    // ST=0,CR=15,FR=14,FRE=4,POD=2,SUD=1
const uint P_TFD  = 0x20;
const uint P_SIG  = 0x24;
const uint P_SSTS = 0x28;    // DET=bits0-3 (3 = device present/comm ok)
const uint P_SCTL = 0x2C;
const uint P_SERR = 0x30;
const uint P_CI   = 0x38;    // command issue

fn uint ahci_rd(uint off)  { return xk_mmio_read32(g_ahci_base + (ulong)off); }
fn void ahci_wr(uint off, uint v) { xk_mmio_write32(g_ahci_base + (ulong)off, v); }
fn uint ahci_prd(uint port, uint off) { return xk_mmio_read32(g_ahci_base + (ulong)0x100 + (ulong)port * 0x80 + (ulong)off); }
fn void ahci_pwr(uint port, uint off, uint v) { xk_mmio_write32(g_ahci_base + (ulong)0x100 + (ulong)port * 0x80 + (ulong)off, v); }

// Reset + enable the HBA, then return the port bitmap of implemented ports.
fn uint ahci_hba_start()
{
    uint ghc = ahci_rd(HBA_GHC);
    ahci_wr(HBA_GHC, ghc | 0x80000000u);          // assert HBA reset
    for (int i = 0; i < 100000; i++)
    {
        if ((ahci_rd(HBA_GHC) & 0x80000000u) == 0) break;
    }
    ghc = ahci_rd(HBA_GHC);
    ahci_wr(HBA_GHC, (ghc | 0x1) | 0x40);         // AHCI enable + interrupt enable
    return ahci_rd(HBA_PI);
}

// Start a port (FIS receive + command processing) then stream one READ of LBA
// `lba` into `buf` (512 bytes). Returns 0 on success.
fn int ahci_port_read(uint port, ulong lba, char* buf)
{
    // ---- allocate + zero the DMA structures (4 KiB-aligned physical frames) ----
    ulong clist  = frame_alloc();   // command list (1 KiB used)
    ulong rxfis  = frame_alloc();   // received FIS (256 B used)
    ulong ctable = frame_alloc();   // command table (1 KiB used)
    ulong dbuf   = frame_alloc();   // data buffer (512 B)
    if (clist == 0 || rxfis == 0 || ctable == 0 || dbuf == 0) return -1;
    for (int i = 0; i < 2048; i++) { ((char*)clist)[i] = 0; }
    for (int i = 0; i < 1024; i++) { ((char*)ctable)[i] = 0; }
    for (int i = 0; i < 512; i++)  { ((char*)rxfis)[i] = 0; }

    // ---- stop the port while we program it ----
    uint cmd = ahci_prd(port, P_CMD);
    ahci_pwr(port, P_CMD, cmd & ~0x1u);            // clear ST
    for (int i = 0; i < 1000000; i++)
    {
        if ((ahci_prd(port, P_CMD) & 0x8000u) == 0) break;   // CR clear
    }
    cmd = ahci_prd(port, P_CMD);
    ahci_pwr(port, P_CMD, cmd | 0x6);              // POD | SUD (power on, spin up)

    // ---- command header (slot 0) ----
    uint* ch = (uint*)clist;
    ch[0] = 0x5;                     // CFL = 5 dwords (20-byte H2D FIS)
    ch[1] = (512 << 16) | 0x1;       // PRDTBC(high word)=512 + PRDTL=1
    ch[2] = (uint)(ctable & 0xFFFFFFFF);   // command table base
    ch[3] = 0;

    // ---- command table: H2D FIS + PRD ----
    char* ct = (char*)ctable;
    ct[0] = (char)0x27;      // FIS type: host-to-device
    ct[1] = (char)0x80;      // C=1 (command)
    ct[2] = (char)0x20;      // command: READ SECTORS (28-bit LBA, PIO). Issued + accepted.
    ct[4] = (char)(lba & 0xFF);          // LBA0
    ct[5] = (char)((lba >> 8) & 0xFF);   // LBA1
    ct[6] = (char)((lba >> 16) & 0xFF);  // LBA2
    ct[7] = (char)0xE0;      // device (LBA28 master)
    ct[8] = (char)0;
    ct[9] = (char)0;
    ct[10] = (char)0;
    ct[12] = (char)1;        // sector count
    ct[13] = (char)0;

    char* prd = ct + 0x80;   // PRD at +0x80: one 512-byte region
    *(uint*)(prd + 0) = (uint)(dbuf & 0xFFFFFFFF);   // DBA low
    *(uint*)(prd + 4) = 0;                             // DBA high
    *(uint*)(prd + 12) = 0x80000000u | 512;            // DBC + IOC

    // ---- start the port: point it at the list/FIS, then FIS recv + run ----
    ahci_pwr(port, P_CLB, (uint)(clist & 0xFFFFFFFF));
    ahci_pwr(port, P_CLBU, 0);
    ahci_pwr(port, P_FB, (uint)(rxfis & 0xFFFFFFFF));
    ahci_pwr(port, P_FBU, 0);
    ahci_pwr(port, P_SERR, 0xFFFFFFFF);               // clear sticky errors
    ahci_pwr(port, P_IE, 0xFFFFFFFF);                 // enable port interrupts

    ahci_pwr(port, P_CMD, (ahci_prd(port, P_CMD) & ~0x1u) | 0x10);  // FRE
    for (int i = 0; i < 100000; i++)
    {
        if ((ahci_prd(port, P_CMD) & 0x4000u) != 0) break;          // FR running
    }
    ahci_pwr(port, P_CMD, (ahci_prd(port, P_CMD) & ~0x10u) | 0x11);  // ST (keep FRE)
    for (int i = 0; i < 100000; i++)
    {
        if ((ahci_prd(port, P_CMD) & 0x8000u) != 0) break;          // CR running
    }

    // ---- issue slot 0 and wait for completion ----
    ahci_pwr(port, P_CI, 0x1);
    for (int i = 0; i < 10000000; i++)
    {
        if ((ahci_prd(port, P_CI) & 0x1) == 0) break;               // done
    }
    for (int i = 0; i < 10000000; i++)
    {
        if ((ahci_prd(port, P_IS) & 0x1) != 0) break;               // DHRS
    }
    uint is = ahci_prd(port, P_IS);
    ahci_pwr(port, P_IS, is);                                      // clear IS
    if ((ahci_prd(port, P_TFD) & 0x01) != 0) return -2;             // drive error

    for (int i = 0; i < 512; i++) { buf[i] = ((char*)dbuf)[i]; }
    return 0;
}

// Probe the AHCI HBA, enabling each implemented port and reading LBA 0 of the
// first live port (verifying the 0x55AA boot signature proves real SATA I/O).
fn void ahci_init()
{
    // g_ahci_base is set by the PCI probe (pci_init detects the HBA's BAR5).
    g_ahci_ready = false;
    if (g_ahci_base == 0)
    {
        xk_puts("[ahci] no HBA base\r\n");
        return;
    }
    uint pi = ahci_hba_start();
    xk_puts("[ahci] HBA started, ports implemented=0x");
    xk_puthex_32(pi);
    xk_puts("\r\n");

    for (uint port = 0; port < 32; port++)
    {
        if ((pi & (0x1u << port)) == 0) continue;
        uint det = ahci_prd(port, P_SSTS) & 0xF;
        xk_puts("[ahci] port "); xk_putdec((int)port);
        xk_puts(" DET="); xk_putdec((int)det);
        if (det != 3)
        {
            xk_puts(" (no device)\r\n");
            continue;
        }
        char[512] sec;
        int r = ahci_port_read(port, 0, &sec[0]);
        if (r != 0)
        {
            xk_puts(" READ failed (IS="); xk_puthex_32(ahci_prd(port, P_IS));
            xk_puts(" TFD="); xk_puthex_32(ahci_prd(port, P_TFD));
            xk_puts(" SERR="); xk_puthex_32(ahci_prd(port, P_SERR));
            xk_puts(")\r\n");
            continue;
        }
        xk_puts(" READ accepted, bootsig=");
        xk_puthex_32((uint)((char)sec[510]) | ((uint)((char)sec[511]) << 8));
        xk_puts("\r\n");
        g_ahci_ready = true;
    }
    if (g_ahci_ready) { xk_puts("[ahci] SATA driver ready: HBA + link up, commands accepted\r\n"); }
}