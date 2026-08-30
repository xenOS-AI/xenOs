module xk;

// ============================================================================
// xenOS Ethernet driver for the Intel 8254x/e1000 NIC (QEMU's default model).
// Polling model (no NIC interrupts) so it's reliable under TCG without IRQ
// routing; the desktop loop calls net_poll() each tick and net_send() emits.
// The guest is 10.0.2.15 on QEMU's slirp user-mode network (gateway 10.0.2.2).
// Everything is identity-mapped, so DMA "physical" addresses == linear.
// ============================================================================

// ---- e1000 register offsets (bar0) ----
const uint N_CTRL  = 0x0000;
const uint N_STATUS= 0x0008;
const uint N_ICR   = 0x00C0;
const uint N_IMS   = 0x00D0;
const uint N_IMR   = 0x00D4;
const uint N_RCTL  = 0x0100;
const uint N_TCTL  = 0x0400;
const uint N_RDBAL = 0x2800;
const uint N_RDBAH = 0x2804;
const uint N_RDLEN = 0x2808;
const uint N_RDH   = 0x2810;
const uint N_RDT   = 0x2818;
const uint N_TDBAL = 0x3800;
const uint N_TDBAH = 0x3804;
const uint N_TDLEN = 0x3808;
const uint N_TDH   = 0x3810;
const uint N_TDT   = 0x3818;
const uint N_RAL   = 0x5400;
const uint N_RAH   = 0x5404;

const int  NET_RX_DESC = 32;
const int  NET_TX_DESC = 32;
const int  NET_BUF_SZ  = 2048;
const int  NET_MTU     = 1500;

const uint E1000_VID = 0x8086;
const uint E1000_DID = 0x100E;

// ---- descriptor formats (16 bytes each) ----
struct NetRxDesc
{
    ulong addr;
    ushort length;
    ushort checksum;
    char status;     // bit0 DD
    char errors;
    ushort special;
}
struct NetTxDesc
{
    ulong addr;
    ushort length;
    char cso;
    char cmd;        // EOP|IFCS|RS
    char status;     // bit0 DD
    char css;
    ushort special;
}

bool    g_net_up;
ulong   g_net_bar;
NetRxDesc[NET_RX_DESC] g_rx_desc;
NetTxDesc[NET_TX_DESC] g_tx_desc;
ulong[NET_RX_DESC] g_rx_buf;
ulong[NET_TX_DESC] g_tx_buf;
int g_rx_cur;      // software head of the RX ring
int g_tx_cur;      // software head of the TX ring

// Ethernet MAC address of this NIC (see net_hw_addr).
char[6] g_net_mac;
char[6] g_gw_mac;             // resolved gateway MAC (ARP)
bool     g_gw_mac_valid;
uint     g_net_ip = 0x0A00020F; // 10.0.2.15 : bytes [10,0,2,15] big-endian
uint     g_gw_ip  = 0x0A000202; // 10.0.2.2  : bytes [10,0,2,2]  big-endian
uint     g_net_next_seqn;       // for ARP, not used

fn uint mmio32(ulong off) { return xk_mmio_read32(g_net_bar + off); }
fn void mmio_w32(ulong off, uint v) { xk_mmio_write32(g_net_bar + off, v); }

// Software reset + link up. Returns true when detected & usable.
fn bool net_hw_reset()
{
    mmio_w32(N_CTRL, 0x00000001);          // CTRL.RST
    for (int i = 0; i < 100; i++)
    {
        xk_pause();
        if ((mmio32(N_CTRL) & 1) == 0) break;
    }
    mmio_w32(N_CTRL, 0x00000040);          // CTRL.SLU (set link up), ASDE off
    // read MAC from RAL/RAH
    uint ral = mmio32(N_RAL);
    uint rah = mmio32(N_RAH);
    g_net_mac[0] = (char)(ral & 0xFF);
    g_net_mac[1] = (char)((ral >> 8) & 0xFF);
    g_net_mac[2] = (char)((ral >> 16) & 0xFF);
    g_net_mac[3] = (char)((ral >> 24) & 0xFF);
    g_net_mac[4] = (char)(rah & 0xFF);
    g_net_mac[5] = (char)((rah >> 8) & 0xFF);
    // write back RAL/RAH and set the receive-address-valid bit (bit31) so the
    // NIC accepts unicast frames addressed to this MAC.
    mmio_w32(N_RAL, ral);
    mmio_w32(N_RAH, rah | 0x80000000);
    return true;
}

fn bool net_rx_init()
{
    // the NIC reads RX descriptors from THIS array (it is identity-mapped DMA
    // memory), so point the ring at g_rx_desc itself, not a scratch frame.
    ulong ring = (ulong)&g_rx_desc[0];
    for (int i = 0; i < NET_RX_DESC; i++)
    {
        ulong b = frame_alloc();
        if (b == 0) return false;
        g_rx_buf[i] = b;
        g_rx_desc[i].addr = b;
        g_rx_desc[i].status = 0;
    }
    g_rx_cur = 0;
    mmio_w32(N_RDBAL, (uint)(ring & 0xFFFFFFFF));
    mmio_w32(N_RDBAH, (uint)(ring >> 32));
    mmio_w32(N_RDLEN, (uint)(NET_RX_DESC * 16));
    mmio_w32(N_RDH, 0);
    mmio_w32(N_RDT, (uint)(NET_RX_DESC - 1));
    // RCTL.EN | UPE | MPE | BAM | SECRC ; BSIZE default = 2048-byte buffers
    mmio_w32(N_RCTL, 0x2 | 0x8 | 0x10 | 0x8000 | 0x4000000);
    return true;
}

fn bool net_tx_init()
{
    ulong ring = (ulong)&g_tx_desc[0];
    for (int i = 0; i < NET_TX_DESC; i++)
    {
        ulong b = frame_alloc();
        if (b == 0) return false;
        g_tx_buf[i] = b;
        g_tx_desc[i].addr = b;
        g_tx_desc[i].status = 0;
    }
    g_tx_cur = 0;
    mmio_w32(N_TDBAL, (uint)(ring & 0xFFFFFFFF));
    mmio_w32(N_TDBAH, (uint)(ring >> 32));
    mmio_w32(N_TDLEN, (uint)(NET_TX_DESC * 16));
    mmio_w32(N_TDH, 0);
    mmio_w32(N_TDT, 0);
    mmio_w32(N_TCTL, 0x0004010A);   // EN | PSP | CT=16 | COLD=0x40
    return true;
}

// ---- Ethernet frame send: raw bytes already framed by caller ----
fn int net_send(void* frame, int len)
{
    if (!g_net_up || len > NET_MTU) return -1;
    int idx = g_tx_cur;
    // wait until this descriptor is free (DD set or first use)
    for (int t = 0; t < 2000; t++)
    {
        if (g_tx_desc[idx].status == 0) break;
        xk_pause();
    }
    // copy frame into the TX buffer
    for (int i = 0; i < len; i++) ((char*)g_tx_buf[idx])[i] = ((char*)frame)[i];
    g_tx_desc[idx].length = (ushort)len;
    g_tx_desc[idx].cmd = (char)0x0B;       // EOP | IFCS | RS
    g_tx_desc[idx].status = 0;
    g_tx_cur = (idx + 1) % NET_TX_DESC;
    mmio_w32(N_TDT, (uint)g_tx_cur);
    // wait for transmit complete
    for (int t = 0; t < 4000; t++)
    {
        if ((g_tx_desc[idx].status & 1) != 0) break;
        xk_pause();
    }
    return 0;
}

// ---- Ethernet frame send: wrap a raw buffer into an Ethernet frame ----
fn void net_send_frame(uint dst0, uint dst1, ushort ethertype, void* payload, int paylen)
{
    if (paylen + 14 > NET_MTU) return;
    char[NET_MTU] fb;
    fb[0] = (char)(dst0 & 0xFF);
    fb[1] = (char)((dst0 >> 8) & 0xFF);
    fb[2] = (char)((dst0 >> 16) & 0xFF);
    fb[3] = (char)((dst0 >> 24) & 0xFF);
    fb[4] = (char)(dst1 & 0xFF);
    fb[5] = (char)((dst1 >> 8) & 0xFF);
    fb[6] = g_net_mac[0]; fb[7] = g_net_mac[1]; fb[8] = g_net_mac[2];
    fb[9] = g_net_mac[3]; fb[10]= g_net_mac[4]; fb[11]= g_net_mac[5];
    fb[12] = (char)((ethertype >> 8) & 0xFF);
    fb[13] = (char)(ethertype & 0xFF);
    for (int i = 0; i < paylen; i++) fb[14 + i] = ((char*)payload)[i];
    net_send(&fb[0], 14 + paylen);
}

// ---- Ethernet frame receive: parse + dispatch up the stack ----
fn void net_poll()
{
    if (!g_net_up) return;
    int processed = 0;
    while (processed < 64)
    {
        NetRxDesc* d = &g_rx_desc[g_rx_cur];
        if ((d.status & 1) == 0) break;       // DD not set yet
        int len = (int)d.length;
        char* pkt = (char*)d.addr;
        // dispatch Ethernet (network layer handled in xk_ip.c3)
        if (len >= 14) net_eth_input(pkt, len);
        d.status = 0;
        g_rx_cur = (g_rx_cur + 1) % NET_RX_DESC;
        // give the descriptor back (tail = one behind head)
        mmio_w32(N_RDT, (uint)(g_rx_cur == 0 ? NET_RX_DESC - 1 : g_rx_cur - 1));
        processed++;
    }
}

// ---- boot-time network self-test (headless-verifiable) ----
fn void net_selftest()
{
    if (!g_net_up) return;
    xk_puts("[net] selftest: resolving gateway 10.0.2.2 via ARP\\r\\n");
    arp_request();
    // poll for a short while (ARP reply), print what happened
    for (int t = 0; t < 200000; t++)
    {
        net_poll();
        if (g_gw_mac_valid) break;
        xk_pause();
    }
    xk_puts("[net] selftest: gateway ARP resolved = ");
    xk_putdec((int)(g_gw_mac_valid ? 1 : 0));
    xk_puts("\\r\\n");
}

// ---- top-level: detect + init e1000 ----
fn bool net_init()
{
    g_net_up = false;
    // find the e1000 on PCI (vendor 0x8086, device 0x100E)
    ulong bar = 0;
    uint ebus = 0;
    uint edev = 0;
    for (uint bus = 0; bus < 2 && bar == 0; bus++)
    {
        for (uint dev = 0; dev < 32 && bar == 0; dev++)
        {
            uint vd = pci_rd(bus, dev, 0, 0);
            if ((vd & 0xFFFF) != 0xFFFF)
            {
                uint vend = vd & 0xFFFF;
                uint did = vd >> 16;
                if (vend == E1000_VID && did == E1000_DID)
                {
                    ebus = bus; edev = dev;
                    bar = (ulong)(pci_rd(bus, dev, 0, 0x10) & 0xFFFFFFF0u);
                }
            }
        }
    }
    if (bar == 0)
    {
        xk_puts("[net] no e1000 NIC found; networking disabled\r\n");
        return false;
    }
    // CRITICAL: enable bus-mastering (PCI Command bit 0x04) or QEMU disables
    // the device's DMA engine entirely (pci_dma_read/write return nothing).
    pci_enable_bus_master(ebus, edev, 0);
    g_net_bar = bar;
    xk_puts("[net] e1000 NIC @ bar0=");
    xk_puthex(bar);
    xk_puts("\r\n");
    net_hw_reset();
    if (!net_rx_init()) { xk_puts("[net] RX init failed\r\n"); return false; }
    if (!net_tx_init()) { xk_puts("[net] TX init failed\r\n"); return false; }
    g_net_up = true;
    xk_puts("[net] MAC=");
    for (int i = 0; i < 6; i++) { xk_puthex_32((uint)g_net_mac[i]); if (i < 5) xk_putc(':'); }
    xk_puts("  up on 10.0.2.15 gw 10.0.2.2\r\n");
    return true;
}