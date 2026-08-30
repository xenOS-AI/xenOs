module xk;

// ============================================================================
// xenOS minimal TCP client (single connection, for the HTTP request path).
// Drives: CLOSED -> SYN/SYN-ACK -> ESTABLISHED, then sends data segments and
// accumulates received bytes (including any FIN). This is deliberately the
// smallest practical client to carry an HTTP transaction to a local host; it
// is not a general TCP stack. Destination is the slirp gateway (10.0.2.2).
// ============================================================================

const uint TCPFLAG_FIN = 1;
const uint TCPFLAG_SYN = 2;
const uint TCPFLAG_RST = 4;
const uint TCPFLAG_PSH = 8;
const uint TCPFLAG_ACK = 16;

const int TCP_ST_CLOSED  = 0;
const int TCP_ST_SYNSENT = 1;
const int TCP_ST_ESTAB   = 2;

const uint TCP_SRC_PORT = 40000;

// connection state
int  g_tcp_state = TCP_ST_CLOSED;
uint g_tcp_dst_port;
uint g_seq, g_ack;
char[8192] g_tcp_data;
int  g_tcp_dlen;

// Build the TCP checksum (pseudo-header + TCP header + data).
fn ushort tcp_checksum(char* hdr, int hlen, char* data, int dlen, uint src_ip, uint dst_ip)
{
    char[8232] buf;    // 12 pseudo + up to 20 tcp + data
    int tot = 12 + hlen + dlen;
    // pseudo header
    buf[0] = (char)((src_ip >> 24) & 0xFF); buf[1] = (char)((src_ip >> 16) & 0xFF);
    buf[2] = (char)((src_ip >> 8) & 0xFF);  buf[3] = (char)(src_ip & 0xFF);
    buf[4] = (char)((dst_ip >> 24) & 0xFF); buf[5] = (char)((dst_ip >> 16) & 0xFF);
    buf[6] = (char)((dst_ip >> 8) & 0xFF);  buf[7] = (char)(dst_ip & 0xFF);
    buf[8] = 0;
    buf[9] = (char)IPPROTO_TCP;
    int tlen = hlen + dlen;
    buf[10] = (char)((tlen >> 8) & 0xFF);
    buf[11] = (char)(tlen & 0xFF);
    for (int i = 0; i < hlen; i++) buf[12 + i] = hdr[i];
    for (int i = 0; i < dlen; i++) buf[12 + hlen + i] = data[i];
    return net_checksum((char*)&buf[0], tot);
}

// Send a TCP segment (header + optional payload) to g_gw_ip:g_tcp_dst_port.
fn void tcp_send(uint flags, uint seq, uint ack, char* payload, int plen)
{
    char[20] th;
    th[0] = (char)((TCP_SRC_PORT >> 8) & 0xFF); th[1] = (char)(TCP_SRC_PORT & 0xFF);
    th[2] = (char)((g_tcp_dst_port >> 8) & 0xFF); th[3] = (char)(g_tcp_dst_port & 0xFF);
    th[4] = (char)((seq >> 24) & 0xFF); th[5] = (char)((seq >> 16) & 0xFF);
    th[6] = (char)((seq >> 8) & 0xFF);  th[7] = (char)(seq & 0xFF);
    th[8] = (char)((ack >> 24) & 0xFF); th[9] = (char)((ack >> 16) & 0xFF);
    th[10] = (char)((ack >> 8) & 0xFF); th[11] = (char)(ack & 0xFF);
    th[12] = (char)0x50;                    // data offset 5 (20 bytes)
    th[13] = (char)(flags & 0x1F);          // TCP flags (byte 13, not 12!)
    th[14] = 0x40; th[15] = 0x00;              // window = 0x40
    th[16] = 0; th[17] = 0;                    // checksum placeholder
    th[18] = 0; th[19] = 0;                    // urgent pointer
    ushort cs = tcp_checksum(&th[0], 20, payload, plen, g_net_ip, g_gw_ip);
    th[16] = (char)((cs >> 8) & 0xFF);
    th[17] = (char)(cs & 0xFF);
    // build contiguous segment = header + payload and send via IP
    char[8232] seg;
    for (int i = 0; i < 20; i++) seg[i] = th[i];
    for (int i = 0; i < plen; i++) seg[20 + i] = payload[i];
    ip_send(IPPROTO_TCP, g_gw_ip, &seg[0], 20 + plen);
}

// ---- incoming TCP segment from ip_input ----
fn void tcp_input(char* seg, int len, uint src_ip)
{
    (void)src_ip;
    if (len < 20) return;
    // extract header
    uint th_src = ((uint)((char)seg[0]) << 8) | (uint)((char)seg[1]);
    uint th_dst = ((uint)((char)seg[2]) << 8) | (uint)((char)seg[3]);
    uint th_ack = ((uint)((char)seg[8]) << 24) | ((uint)((char)seg[9]) << 16) |
                  ((uint)((char)seg[10]) << 8) | (uint)((char)seg[11]);
    uint flags = (uint)((char)seg[13]) & 0x1F;
    int doff = ((int)((char)seg[12]) >> 4) * 4;
    if (doff < 20 || doff > len) return;
    // only handle the segment addressed to our ephemeral port
    if (th_dst != TCP_SRC_PORT) return;
    int dlen = len - doff;

    if (g_tcp_state == TCP_ST_SYNSENT && (flags & TCPFLAG_SYN) != 0)
    {
        // SYN-ACK: our local sequence becomes the remote ACK
        g_seq = th_ack;                 // remote acknowledged our SYN (seq+1)
        uint their_seq = ((uint)((char)seg[4]) << 24) | ((uint)((char)seg[5]) << 16) |
                         ((uint)((char)seg[6]) << 8) | (uint)((char)seg[7]);
        g_ack = their_seq + 1;
        g_tcp_state = TCP_ST_ESTAB;
        // send our ACK
        tcp_send(TCPFLAG_ACK, g_seq, g_ack, null, 0);
        return;
    }
    if (g_tcp_state == TCP_ST_ESTAB)
    {
        char* d = &seg[doff];
        for (int i = 0; i < dlen && g_tcp_dlen < 8192; i++)
        {
            g_tcp_data[g_tcp_dlen++] = d[i];
        }
        g_ack = th_ack;
        // ack received data (advance our seq by the payload size we sent)
        if (dlen > 0 && (flags & TCPFLAG_ACK) != 0)
        {
            tcp_send(TCPFLAG_ACK, g_seq, g_ack, null, 0);
        }
        // if it closes, note ESTAB stays but caller sees dlen/data
        return;
    }
}

// Establish a connection to g_gw_ip:dst_port.
fn int tcp_connect(uint dst_port)
{
    g_tcp_dst_port = dst_port;
    g_tcp_dlen = 0;
    g_tcp_state = TCP_ST_SYNSENT;
    g_seq = 1000;                       // initial local sequence
    g_ack = 0;
    tcp_send(TCPFLAG_SYN, g_seq, 0, null, 0);
    g_seq++;                            // SYN consumes one seq
    // wait for SYN-ACK (net_poll drives receipt)
    for (int t = 0; t < 600000; t++)
    {
        net_poll();
        if (g_tcp_state == TCP_ST_ESTAB) return 0;
        if (t % 500000 == 0 && t > 0) arp_request();   // retry ARP occasionally
        xk_pause();
    }
    return -1;
}

// Send a data segment and wait until we hold some bytes back.
fn int tcp_send_and_recv(char* data, int len, char* out, int outcap, int* outlen, int timeout)
{
    tcp_send(TCPFLAG_PSH | TCPFLAG_ACK, g_seq, g_ack, data, len);
    g_seq += (uint)len;
    int start = g_tcp_dlen;
    for (int t = 0; t < timeout; t++)
    {
        net_poll();
        if (g_tcp_dlen > start) break;
        xk_pause();
    }
    // hand over whatever arrived
    if (g_tcp_dlen > 0)
    {
        int n = g_tcp_dlen;
        if (n > outcap) n = outcap;
        for (int i = 0; i < n; i++) out[i] = g_tcp_data[i];
        *outlen = n;
        g_tcp_dlen = 0;
        return 0;
    }
    return -1;
}