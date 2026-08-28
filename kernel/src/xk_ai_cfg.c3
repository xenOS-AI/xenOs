module xk;

// ============================================================================
// xenOS AI provider configuration: reads AI.CFG from the FAT16 data volume at
// boot. The three fields the user asked for: model name, endpoint URL, token.
// Layout (one per line, no spaces around '='):
//     model=<name>
//     endpoint=<base url>
//     token=<token>
// Token is shown masked on screen; never logged in full.
// ============================================================================

const uint AI_MODEL_LEN    = 64;
const uint AI_ENDPOINT_LEN = 128;
const uint AI_TOKEN_LEN    = 128;
const uint AI_CFG_BUF      = 2048;

struct AiCfg
{
    bool valid;
    char[AI_MODEL_LEN]    model;
    char[AI_ENDPOINT_LEN] endpoint;
    char[AI_TOKEN_LEN]    token;
}
AiCfg g_ai_cfg;

// ---- tiny string helpers (freestanding; no libc) ----
fn uint ai_strlen(char* s)
{
    uint n = 0;
    while (s[n] != 0) n++;
    return n;
}

fn void ai_strcpy(char* d, char* s)
{
    uint i = 0;
    while (s[i] != 0) { d[i] = s[i]; i++; }
    d[i] = 0;
}

fn bool ai_streq(char* a, char* b)
{
    uint i = 0;
    while (a[i] != 0 && a[i] == b[i]) i++;
    return a[i] == b[i];
}

// trim trailing \r / \n / space / tab
fn void ai_strtrim_tail(char* s)
{
    uint n = ai_strlen(s);
    while (n > 0)
    {
        char c = s[n - 1];
        if (c == '\r' || c == '\n' || c == ' ' || c == '\t') { n--; s[n] = 0; }
        else { break; }
    }
}

// copy a field value (trimmed) if it fits
fn void ai_cfg_set_field(char* out, uint cap, char* value)
{
    ai_strtrim_tail(value);
    uint v = ai_strlen(value);
    if (v >= cap) v = cap - 1;
    for (uint i = 0; i < v; i++) out[i] = value[i];
    out[v] = 0;
}

// Is a key-name string (already NUL-terminated, length klen) equal to `name`?
fn bool ai_key_is(char* key, uint klen, char* name)
{
    uint n = 0;
    while (name[n] != 0) n++;
    if (klen != n) return false;
    for (uint i = 0; i < klen; i++)
    {
        if (key[i] != name[i]) return false;
    }
    return true;
}

// Parse one "key=value" line and store it into the running config.
fn void ai_cfg_parse_line(char* line)
{
    uint i = 0;
    while (line[i] != 0 && line[i] != '=') i++;
    if (line[i] != '=') return;
    uint klen = i;
    char* key = &line[0];
    char* val = &line[i + 1];
    if (ai_key_is(key, klen, "model"))       { ai_cfg_set_field(&g_ai_cfg.model[0],    AI_MODEL_LEN,    val); }
    else if (ai_key_is(key, klen, "endpoint")) { ai_cfg_set_field(&g_ai_cfg.endpoint[0], AI_ENDPOINT_LEN, val); }
    else if (ai_key_is(key, klen, "token"))  { ai_cfg_set_field(&g_ai_cfg.token[0],    AI_TOKEN_LEN,    val); }
}

// Load and parse AI.CFG from the FAT volume. Called after fat_mount().
fn bool ai_cfg_load()
{
    g_ai_cfg.valid = false;
    g_ai_cfg.model[0] = 0;
    g_ai_cfg.endpoint[0] = 0;
    g_ai_cfg.token[0] = 0;
    if (!g_fat_mounted) return false;
    char[AI_CFG_BUF] buf;
    uint len = 0;
    if (fat_read_file("AI.CFG", &buf[0], AI_CFG_BUF, &len) != 0) return false;
    // ensure NUL-terminated
    if (len >= AI_CFG_BUF) len = AI_CFG_BUF - 1;
    buf[len] = 0;
    // split into lines
    uint start = 0;
    for (uint i = 0; i <= len; i++)
    {
        if (buf[i] == '\n' || buf[i] == 0)
        {
            buf[i] = 0;
            ai_cfg_parse_line(&buf[start]);
            start = i + 1;
        }
    }
    g_ai_cfg.valid = g_ai_cfg.model[0] != 0 && g_ai_cfg.endpoint[0] != 0 && g_ai_cfg.token[0] != 0;
    return g_ai_cfg.valid;
}

// Is a provider fully configured?
fn bool ai_cfg_ready()
{
    return g_ai_cfg.valid;
}

// Print the config to the terminal (token masked to the first 4 chars).
fn void ai_cfg_show()
{
    term_puts("AI provider config (AI.CFG):\r\n");
    if (!ai_cfg_ready())
    {
        term_puts("  NOT fully configured (need model/endpoint/token)\r\n");
    }
    term_puts("  model = ");
    term_puts(&g_ai_cfg.model[0]); term_puts("\r\n");
    term_puts("  endpoint = ");
    term_puts(&g_ai_cfg.endpoint[0]); term_puts("\r\n");
    term_puts("  token = ");
    // masked
    if (g_ai_cfg.token[0] != 0)
    {
        char[5] head;
        uint i;
        for (i = 0; i < 4 && g_ai_cfg.token[i] != 0; i++) head[i] = g_ai_cfg.token[i];
        head[i] = 0;
        term_puts(&head[0]);
        term_puts(".... (");
        term_putdec((int)ai_strlen(&g_ai_cfg.token[0]));
        term_puts(" chars)\r\n");
    }
    else
    {
        term_puts("(none)\r\n");
    }
}

// Load config at boot (called from xk_boot after fat_mount()).
fn void ai_cfg_init()
{
    if (ai_cfg_load())
    {
        xk_puts("[ai] provider config loaded (AI.CFG)\r\n");
    }
    else
    {
        xk_puts("[ai] no valid AI.CFG (run: set model/endpoint/token on the volume)\r\n");
    }
}