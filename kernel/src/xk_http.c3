module xk;

// ============================================================================
// xenOS HTTP/1.1 client (transport for the AI chat client).
// Talks to QEMU's slirp gateway (10.0.2.2) which hostfwd-forwards host port
// 9080 into the guest -> a local mock provider on the host. This is the
// shippable local path (the plan's TLS decision point): real public-Internet
// HTTPS/TLS remains a separate milestone. Replaces the mock transport once the
// NIC is up. It parses the endpoint base URL from AI.CFG for host:port.
// ============================================================================

const uint HTTP_BUF = 8192;

// Extract the port from an "http://host[:port]" endpoint string.
fn uint http_endpoint_port(char* ep)
{
    uint p = 80;
    // skip "http://" if present
    uint i = 0;
    if (ep[0] == 'h' && ep[1] == 't' && ep[2] == 't' && ep[3] == 'p') { i = 7; }
    // find ':'
    while (ep[i] != 0 && ep[i] != ':') i++;
    if (ep[i] == ':')
    {
        uint port = 0;
        i++;
        while (ep[i] >= '0' && ep[i] <= '9')
        {
            port = port * 10 + (uint)(ep[i] - '0');
            i++;
        }
        return port;
    }
    return p;
}

// HTTP transport plugged into the AI client (g_ai_transport).
fn int http_transport(char* req, uint req_len, char* resp, uint* resp_len)
{
    if (!g_net_up) return -1;
    uint port = http_endpoint_port(&g_ai_cfg.endpoint[0]);
    // build the raw HTTP request string
    char[HTTP_BUF] http;
    uint o = 0;
    char* reqline = "POST /chat/completions HTTP/1.1\r\n";
    for (uint i = 0; reqline[i] != 0 && o < HTTP_BUF - 1; i++) http[o++] = reqline[i];
    // Host header
    char* host = &g_ai_cfg.endpoint[0];
    // skip "http://"
    uint hh = 0;
    if (host[0]=='h'&&host[1]=='t'&&host[2]=='t'&&host[3]=='p') hh = 7;
    char* hb = "Host: ";
    for (uint i = 0; hb[i] != 0 && o < HTTP_BUF - 1; i++) http[o++] = hb[i];
    // host up to '/' or ':' (keep the port so slirp hostfwd routes it)
    uint portdps = 0;
    while (host[hh] != 0 && host[hh] != '/' && host[hh] != ':' && o < HTTP_BUF - 1 && portdps < 80)
    {
        http[o++] = host[hh]; hh++; portdps++;
    }
    // append :port
    char* colon = ":";
    for (uint i = 0; colon[i] != 0 && o < HTTP_BUF - 1; i++) http[o++] = colon[i];
    char[8] pb; uint pn = 0; uint pv = port;
    if (pv == 0) { pb[pn++] = '0'; }
    while (pv > 0) { pb[pn++] = (char)('0' + (pv % 10)); pv /= 10; }
    for (uint i = 0; i < pn; i++) http[o++] = pb[pn - 1 - i];
    char* crlf = "\r\n";
    for (uint i = 0; crlf[i] != 0 && o < HTTP_BUF - 1; i++) http[o++] = crlf[i];
    // Authorization
    char* auth = "Authorization: Bearer ";
    for (uint i = 0; auth[i] != 0 && o < HTTP_BUF - 1; i++) http[o++] = auth[i];
    for (uint i = 0; g_ai_cfg.token[i] != 0 && o < HTTP_BUF - 1; i++) http[o++] = g_ai_cfg.token[i];
    char* authnl = "\r\n";
    for (uint i = 0; authnl[i] != 0 && o < HTTP_BUF - 1; i++) http[o++] = authnl[i];
    // content-type
    char* ct = "Content-Type: application/json\r\n";
    for (uint i = 0; ct[i] != 0 && o < HTTP_BUF - 1; i++) http[o++] = ct[i];
    // content-length + connection close
    char* cl = "Content-Length: ";
    for (uint i = 0; cl[i] != 0 && o < HTTP_BUF - 1; i++) http[o++] = cl[i];
    char[8] lb; uint ln = 0; uint lv = req_len;
    if (lv == 0) { lb[ln++] = '0'; }
    while (lv > 0) { lb[ln++] = (char)('0' + (lv % 10)); lv /= 10; }
    for (uint i = 0; i < ln; i++) http[o++] = lb[ln - 1 - i];
    char* close = "\r\nConnection: close\r\n\r\n";
    for (uint i = 0; close[i] != 0 && o < HTTP_BUF - 1; i++) http[o++] = close[i];
    // body
    for (uint i = 0; i < req_len && o < HTTP_BUF - 1; i++) http[o++] = req[i];
    http[o] = 0;

    // one-shot request: open connection, send, read response
    if (tcp_connect(port) != 0) return -1;
    char[HTTP_BUF] rbuf;
    int rlen = 0;
    if (tcp_send_and_recv(&http[0], (int)o, &rbuf[0], HTTP_BUF, &rlen, 3000000) != 0) return -1;
    if (rlen > 0)
    {
        /* the response body is what contains "content": an HTTP response has
           the JSON after the header block; for leniency we pass the whole
           thing to the AI parser which hunts for the "content" field. */
        if (rlen > (int)HTTP_BUF) rlen = (int)HTTP_BUF;
        for (int i = 0; i < rlen; i++) resp[i] = rbuf[i];
        *resp_len = (uint)rlen;
        return 0;
    }
    return -1;
}

// Register the real HTTP transport (called once the NIC is up).
fn void http_register()
{
    g_ai_transport = &http_transport;
    xk_puts("[http] AI transport switched to live HTTP (10.0.2.2 hostfwd:9080)\r\n");
}