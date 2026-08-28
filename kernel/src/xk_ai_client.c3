module xk;

// ============================================================================
// xenOS AI client: provider-agnostic OpenAI-compatible chat/completions client.
// Builds the request JSON from the config (model/endpoint/token) + a prompt,
// and parses the response to extract choices[0].message.content.
//
// Transport seam: a function pointer `AiTransport` that knows how to turn a
// request buffer into a response buffer (e.g. an HTTP client once networking
// lands, or a mock for now). The client layer is transport-independent.
// ============================================================================

const uint AI_REQ_MAX    = 2048;   // request body buffer
const uint AI_RESP_MAX   = 4096;   // response body buffer
const uint AI_CONTENTLEN = 1024;   // max extracted message content

// Transport: fill resp[] from request req[] (req_len bytes), set *resp_len.
// Returns 0 on success, non-zero on error. Must write a full HTTP body/JSON.
alias AiTransport = fn int(char* req, uint req_len, char* resp, uint* resp_len);
AiTransport g_ai_transport = null;   // registered by the transport layer

// Result of a chat call.
struct AiChatResult
{
    bool ok;
    char[AI_CONTENTLEN] content;
}

// ---- JSON string escaping (minimal: backslash + double-quote + control) ----
fn void ai_json_escape(char* in, char* out, uint outcap, uint* outlen)
{
    uint o = 0;
    uint i = 0;
    while (in[i] != 0 && o < outcap - 2)
    {
        char c = in[i];
        if (c == '\\')      { out[o++] = '\\'; out[o++] = '\\'; }
        else if (c == '"')  { out[o++] = '\\'; out[o++] = '"'; }
        else if (c == '\n') { out[o++] = '\\'; out[o++] = 'n'; }
        else if (c == '\r') { out[o++] = '\\'; out[o++] = 'r'; }
        else if (c == '\t') { out[o++] = '\\'; out[o++] = 't'; }
        else if ((int)c < 0x20) { /* drop other control chars */ }
        else { out[o++] = c; }
        i++;
    }
    out[o] = 0;
    *outlen = o;
}

// Build the chat/completions request body for a single user prompt.
fn void ai_build_request(char* prompt, char* out, uint outcap, uint* outlen)
{
    char[AI_CONTENTLEN] esc;
    uint esclen = 0;
    ai_json_escape(prompt, &esc[0], AI_CONTENTLEN, &esclen);
    uint o = 0;
    char* model = &g_ai_cfg.model[0];
    // {"model":"<model>","messages":[{"role":"user","content":"<esc>"}]}
    out[o++] = '{';
    // model
    char* mi = "\"model\":\"";
    for (uint i = 0; mi[i] != 0 && o < outcap - 1; i++) out[o++] = mi[i];
    for (uint i = 0; model[i] != 0 && o < outcap - 1; i++) out[o++] = model[i];
    char* mq = "\",";
    for (uint i = 0; mq[i] != 0 && o < outcap - 1; i++) out[o++] = mq[i];
    // messages
    char* msg = "\"messages\":[{\"role\":\"user\",\"content\":\"";
    for (uint i = 0; msg[i] != 0 && o < outcap - 1; i++) out[o++] = msg[i];
    for (uint i = 0; i < esclen && o < outcap - 1; i++) out[o++] = esc[i];
    char* tail = "\"}]}";
    for (uint i = 0; tail[i] != 0 && o < outcap - 1; i++) out[o++] = tail[i];
    out[o] = 0;
    *outlen = o;
}

// Extract the first "content":"..." value from a chat/completions response.
// Handles the {"role":"assistant","content":"THE ANSWER"} structure.
fn void ai_parse_content(char* resp, uint len, char* out, uint outcap, uint* outlen)
{
    uint o = 0;
    uint i = 0;
    // scan for the phrase "content":
    while (i + 7 < len && (resp[i] != 'c' ||
           !ai_string_at(resp, i, "content"))) i++;
    // move past "content"
    i += 7;
    // skip whitespace, ':', whitespace, '"'
    while (i < len && (resp[i] == ' ' || resp[i] == '\t' || resp[i] == ':' || resp[i] == '"')) i++;
    // now read until closing unescaped quote
    while (i < len && o < outcap - 1)
    {
        char c = resp[i];
        if (c == '"') break;
        if (c == '\\' && i + 1 < len)
        {
            char n = resp[i + 1];
            if (n == 'n') { out[o++] = '\n'; i += 2; continue; }
            if (n == 'r') { out[o++] = '\r'; i += 2; continue; }
            if (n == 't') { out[o++] = '\t'; i += 2; continue; }
            if (n == '\\' || n == '"') { out[o++] = n; i += 2; continue; }
        }
        out[o++] = c;
        i++;
    }
    out[o] = 0;
    *outlen = o;
}

// Does resp contain the ASCII sequence "key" starting at index i?
fn bool ai_string_at(char* s, uint i, char* key)
{
    uint k = 0;
    while (key[k] != 0)
    {
        if (s[i + k] != key[k]) return false;
        k++;
    }
    return true;
}

// Ask the model a single-turn question. Returns 0 ok (-1 transport error,
// -2 config missing). Content (possibly empty) lands in result.content.
fn int ai_chat(char* prompt, AiChatResult* result)
{
    result.ok = false;
    result.content[0] = 0;
    if (!ai_cfg_ready()) return -2;
    if (g_ai_transport == null) return -1;

    char[AI_REQ_MAX] req;
    uint reqlen = 0;
    ai_build_request(prompt, &req[0], AI_REQ_MAX, &reqlen);

    char[AI_RESP_MAX] resp;
    uint resplen = 0;
    int t = g_ai_transport(&req[0], reqlen, &resp[0], &resplen);
    if (t != 0) return -1;
    if (resplen >= AI_RESP_MAX) resplen = AI_RESP_MAX - 1;
    resp[resplen] = 0;

    uint clen = 0;
    ai_parse_content(&resp[0], resplen, &result.content[0], AI_CONTENTLEN, &clen);
    // if no "content" was found, mirror the raw response as the visible text
    if (clen == 0)
    {
        ai_strcpy(&result.content[0], &resp[0]);
    }
    result.ok = true;
    return 0;
}

// ---- Mock transport: returns a canned assistant reply so the full client +
// ---- parse + chat-box pipeline is exercisable before networking lands.
fn int ai_transport_mock(char* req, uint req_len, char* resp, uint* resp_len)
{
    (void)req; (void)req_len;
    // a realistic chat/completions response fragment with a "content" field
    char* body = "{\"choices\":[{\"message\":{\"role\":\"assistant\","
                 "\"content\":\"Welcome to xenOS AI. This line was produced by the "
                 "in-kernel AI client through the transport seam (mock).\"}}]}";
    uint n = 0;
    while (body[n] != 0 && n < AI_RESP_MAX - 1) { resp[n] = body[n]; n++; }
    resp[n] = 0;
    *resp_len = n;
    return 0;
}

// Register the transport used by ai_chat. The networking stage replaces the
// mock with a real HTTP client; until then the mock is the default.
fn void ai_client_init()
{
    g_ai_transport = &ai_transport_mock;
}