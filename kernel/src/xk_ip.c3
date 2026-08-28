module xk;

// ============================================================================
// xenOS IPv4 + ARP layer on top of the e1000 driver.
//   net_eth_input()   <- Ethernet dispatch  (called from net_poll)
//   arp_request()     <- resolve the gateway MAC (10.0.2.2)
//   ip_send_segment() <- frame an IPv4 packet to the gateway (TCP/etc)
// All addresses are stored big-endian by convention here (byte order matches
// how we write them into headers).
// ============================================================================

const ushort ETHTYPE_ARP = 0x0806;
const ushort ETHTYPE_IP  = 0x0800;
const char  IPPROTO_TCP = 6;

// ---- Internet checksum (RFC 1071) ----
fn ushort net_checksum(char* data, int len)
{
    ulong sum = 0;
    int i = 0;
    while (i + 1 < len)
    {
        sum += (ulong)(((uint)data[i] << 8) | (uint)data[i + 1]);
        i += 2;
    }
    if (i < len) sum += (ulong)((uint)data[i] << 8);
    while ((sum >> 16) != 0)
    {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return (ushort)(~sum & 0xFFFF);
}

// Send an ARP "who-has <g_gw_ip> ? tell <g_net_ip>" to the broadcast address.
fn void arp_request()
{
    char[28] a;
    // htype=1(eth) ptype=0x0800 hlen=6 plen=4
    a[0] = 0; a[1] = 1;
    a[2] = 0x08; a[3] = 0;
    a[4] = 6; a[5] = 4;
    a[6] = 0; a[7] = 1;                         // oper: REQUEST
    // sender hw (our MAC)
    for (int i = 0; i < 6; i++) a[8 + i] = g_net_mac[i];
    // sender proto (our IP)
    a[14] = (char)((g_net_ip >> 24) & 0xFF);
    a[15] = (char)((g_net_ip >> 16) & 0xFF);
    a[16] = (char)((g_net_ip >> 8) & 0xFF);
    a[17] = (char)(g_net_ip & 0xFF);
    // target hw: zero
    for (int i = 0; i < 6; i++) a[18 + i] = 0;
    // target proto: gateway IP
    a[24] = (char)((g_gw_ip >> 24) & 0xFF);
    a[25] = (char)((g_gw_ip >> 16) & 0xFF);
    a[26] = (char)((g_gw_ip >> 8) & 0xFF);
    a[27] = (char)(g_gw_ip & 0xFF);
    net_send_frame(0xFFFFFFFF, 0xFFFF, ETHTYPE_ARP, &a[0], 28);
}

// ---- Ethernet dispatch (called by net_poll) ----
fn void net_eth_input(char* pkt, int len)
{
    if (len < 14) return;
    ushort et = (ushort)(((uint)((char)pkt[12]) << 8) | (uint)((char)pkt[13]));
    char* payload = &pkt[14];
    int plen = len - 14;
    if (et == ETHTYPE_ARP)
    {
        arp_input(payload, plen);
    }
    else if (et == ETHTYPE_IP)
    {
        ip_input(payload, plen);
    }
}

fn void arp_input(char* p, int len)
{
    if (len < 28) return;
    ushort oper = (ushort)(((uint)((char)p[6]) << 8) | (uint)((char)p[7]));
    // operation 2 = reply; 3 = RARP reply (ignored)
    if (oper != 2) return;
    // check it's for our IP (target proto = p[24..27])
    uint tpa = ((uint)((char)p[24]) << 24) | ((uint)((char)p[25]) << 16) |
               ((uint)((char)p[26]) << 8) | (uint)((char)p[27]);
    // sender proto = p[14..17]
    uint spa = ((uint)((char)p[14]) << 24) | ((uint)((char)p[15]) << 16) |
               ((uint)((char)p[16]) << 8) | (uint)((char)p[17]);
    if (spa == g_gw_ip || tpa == g_net_ip)
    {
        for (int i = 0; i < 6; i++) g_gw_mac[i] = (char)p[8 + i];
        g_gw_mac_valid = true;
        xk_puts("[ip] gateway ARP resolved: ");
        for (int i = 0; i < 6; i++) { xk_puthex_32((uint)g_gw_mac[i]); if (i < 5) xk_putc(':'); }
        xk_puts("\r\n");
    }
}

// ---- IPv4 input (TCP is handled in xk_tcp.c3) ----
fn void ip_input(char* p, int len)
{
    if (len < 20) return;
    char ver_ihl = (char)p[0];
    if ((ver_ihl >> 4) != 4) return;
    int ihl = ((int)(ver_ihl & 0x0F)) * 4;
    if (ihl < 20 || len < ihl) return;
    char proto = (char)p[9];
    ushort total = (ushort)(((uint)((char)p[2]) << 8) | (uint)((char)p[3]));
    if ((int)total < ihl) return;
    // source IP (for TCP pseudo-header / reply routing)
    uint src = ((uint)((char)p[12]) << 24) | ((uint)((char)p[13]) << 16) |
               ((uint)((char)p[14]) << 8) | (uint)((char)p[15]);
    int seg_len = len - ihl;
    if (seg_len < 0) return;
    if (proto == IPPROTO_TCP)
    {
        tcp_input(&p[ihl], seg_len, src);
    }
}

// Send an IPv4 segment (proto = IPPROTO_TCP) carrying `payload` of `plen`
// bytes, from our IP:srcport to g_gw_ip:dstport. A 20-byte TCP header is laid
// out by the callers in tcp_send / http building below, but for foreign
// protocols we allow a raw payload with the IP header added here.
fn int ip_send(char proto, uint dst_ip, char* tcp_hdr, int tcp_len)
{
    // ensure the gateway MAC is known
    if (!g_gw_mac_valid)
    {
        arp_request();
        for (int t = 0; t < 400000 && !g_gw_mac_valid; t++)
        {
            net_poll();          // process the ARP reply while waiting
            xk_pause();
        }
        if (!g_gw_mac_valid) return -1;
    }
    char[1500] ipb;
    int iplen = 20 + tcp_len;
    ipb[0] = 0x45;                       // v4, ihl=5
    ipb[1] = 0;                          // TOS
    ipb[2] = (char)((iplen >> 8) & 0xFF);
    ipb[3] = (char)(iplen & 0xFF);
    ipb[4] = 0; ipb[5] = 0;              // id
    ipb[6] = 0x40; ipb[7] = 0;           // DF flag, frag 0
    ipb[8] = 64;                         // TTL
    ipb[9] = (char)proto;
    ipb[10] = 0; ipb[11] = 0;            // checksum placeholder
    ipb[12] = (char)((g_net_ip >> 24) & 0xFF);
    ipb[13] = (char)((g_net_ip >> 16) & 0xFF);
    ipb[14] = (char)((g_net_ip >> 8) & 0xFF);
    ipb[15] = (char)(g_net_ip & 0xFF);
    ipb[16] = (char)((dst_ip >> 24) & 0xFF);
    ipb[17] = (char)((dst_ip >> 16) & 0xFF);
    ipb[18] = (char)((dst_ip >> 8) & 0xFF);
    ipb[19] = (char)(dst_ip & 0xFF);
    // copy TCP header + payload
    for (int i = 0; i < tcp_len; i++) ipb[20 + i] = tcp_hdr[i];
    // IP checksum over the 20-byte header
    ushort cs = net_checksum((char*)&ipb[0], 20);
    ipb[10] = (char)((cs >> 8) & 0xFF);
    ipb[11] = (char)(cs & 0xFF);
    // send to the gateway geo (the IP is local slirp, so gateway's MAC)
    net_send_frame(g_gw_mac[0] | ((ulong)g_gw_mac[1] << 8) | ((ulong)g_gw_mac[2] << 16) | ((ulong)g_gw_mac[3] << 24),
                   g_gw_mac[4] | ((ulong)g_gw_mac[5] << 8),
                   ETHTYPE_IP, &ipb[0], iplen);
    return 0;
}