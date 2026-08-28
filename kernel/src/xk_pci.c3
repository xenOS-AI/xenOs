module xk;
// ============================================================================
// xenOS PCI bus driver (enumerate via the 0xCF8/0xCFC configuration space).
// Probes the real controllers on target hardware (Lenovo ThinkPad X390 Yoga's
// Intel Cannon Point-LP PCH exposes 8086 devices: PCIe root ports, HDA, XHCI,
// I2C/SMBus, I219 Ethernet, NVMe, WLAN), and also enumerates QEMU's I440FX/
// PIIX3 chipset for development. All reads are BIOS-config-safe.
// ============================================================================

const uint PCI_ADDR = 0xCF8;
const uint PCI_DATA = 0xCFC;

extern fn void xk_outl(uint port, uint val);
extern fn uint  xk_inl(uint port);

fn uint pci_rd(uint bus, uint dev, uint func, uint reg)
{
    uint addr = 0x80000000u | (bus << 16) | (dev << 11) | (func << 8) | (reg & 0xFC);
    xk_outl(PCI_ADDR, addr);
    return xk_inl(PCI_DATA);
}

fn char pci_hexc(uint d)
{
    if (d < 10) return (char)('0' + d);
    return (char)('a' + (d - 10));
}
fn void pci_hex(uint v, int digits)
{
    for (int i = digits - 1; i >= 0; i--)
    {
        xk_putc(pci_hexc((v >> (4 * i)) & 0xF));
    }
}

fn void pci_dump_one(uint bus, uint dev, uint func)
{
    uint vd = pci_rd(bus, dev, func, 0);
    uint vend = vd & 0xFFFF;
    uint ddev = vd >> 16;
    uint class = pci_rd(bus, dev, func, 0x08) >> 16;   // class.code in bytes 2-3 of reg 0x08
    xk_puts("  PCI ");
    pci_hex(bus, 1);
    xk_putc(':');
    pci_hex(dev, 2);
    xk_putc('.');
    pci_hex(func, 1);
    xk_puts("  ");
    pci_hex(vend, 4);
    xk_putc(':');
    pci_hex(ddev, 4);
    if (vend == 0x8086) { xk_puts("  [Intel]"); }
    xk_puts("  class=");
    pci_hex(class, 4);
    xk_puts("\r\n");
}

fn void pci_init()
{
    xk_puts("[pci] enumerating PCI bus...\r\n");
    int found = 0;
    ulong ahci_bar = 0;
    for (uint bus = 0; bus < 2; bus++)
    {
        for (uint dev = 0; dev < 32; dev++)
        {
            bool done_dev = false;
            for (uint func = 0; func < 8; func++)
            {
                uint vd = pci_rd(bus, dev, func, 0);
                if ((vd & 0xFFFF) == 0xFFFF)
                {
                    if (func == 0) { done_dev = true; }
                    continue;
                }
                pci_dump_one(bus, dev, func);
                found++;
                // detect an AHCI (SATA host controller): base class 0x01,
                // subclass 0x06 -> config reg 0x08 >> 16 == 0x0106.
                // Grab its ABAR from BAR5 (config reg 0x24).
                if ((pci_rd(bus, dev, func, 0x08) >> 16) == 0x0106)
                {
                    ahci_bar = (ulong)(pci_rd(bus, dev, func, 0x24) & 0xFFFFFFF0u);
                }
                if (func == 0)
                {
                    uint hdr = pci_rd(bus, dev, func, 0x0C);
                    if (((hdr >> 16) & 0x80) == 0) { done_dev = true; }   // not multifunction
                }
                if (done_dev) break;
            }
        }
    }
    xk_puts("[pci] ");
    xk_putdec(found);
    xk_puts(" PCI device(s)\r\n");
    if (ahci_bar != 0)
    {
        xk_puts("[pci] AHCI (SATA) host controller found, ABAR=");
        xk_puthex(ahci_bar);
        xk_puts("\r\n");
        g_ahci_base = ahci_bar;
        ahci_init();
    }
}