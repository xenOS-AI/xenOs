module xk;

// ============================================================================
// xenOS agent layer (Stage 2): an audit journal and a *safe* action grammar
// that turns a model response into a structured windowing action
// (open/close/focus a window). The model never gets raw power — it can only
// pick from a fixed grammar, and every action is journaled ("audit by design").
// Works offline via `ai act-direct <text>`; `ai act <prompt>` first asks the
// provider (via the AI client) then applies the grammar.
// ============================================================================

const int AGT_JOURNAL = 24;
const int AGT_DETAIL  = 64;

struct ActRec
{
    bool used;
    uint ticks;
    char[12] actor;
    char[16] action;
    char[AGT_DETAIL] detail;
    char[20] result;
}
ActRec[AGT_JOURNAL] g_journal;
int g_journal_head;

fn void journal_add(char* action, char* detail, char* result)
{
    ActRec* r = &g_journal[g_journal_head];
    r.used = true;
    r.ticks = (uint)g_ticks;
    r.actor[0] = 'a'; r.actor[1] = 'g'; r.actor[2] = 't'; r.actor[3] = 0;   // "agt"
    // action -> char[16]
    for (int i = 0; i < 15 && action[i] != 0; i++) { r.action[i] = action[i]; r.action[i + 1] = 0; }
    r.action[15] = 0;
    // detail -> char[AGT_DETAIL]
    for (int i = 0; i < AGT_DETAIL - 1 && detail[i] != 0; i++) { r.detail[i] = detail[i]; r.detail[i + 1] = 0; }
    r.detail[AGT_DETAIL - 1] = 0;
    // result -> char[20]
    for (int i = 0; i < 19 && result[i] != 0; i++) { r.result[i] = result[i]; r.result[i + 1] = 0; }
    r.result[19] = 0;
    g_journal_head = (g_journal_head + 1) % AGT_JOURNAL;
}

fn void journal_print()
{
    term_puts("agent action journal:\r\n");
    for (int k = 0; k < AGT_JOURNAL; k++)
    {
        int idx = (g_journal_head + AGT_JOURNAL - 1 - k) % AGT_JOURNAL;   // newest first
        ActRec* r = &g_journal[idx];
        if (!r.used) continue;
        term_puts("  t="); term_putdec((int)r.ticks);
        term_puts(" ");
        term_puts(&r.action[0]);
        term_puts("("); term_puts(&r.detail[0]); term_puts(") -> ");
        term_puts(&r.result[0]);
        term_puts("\r\n");
    }
}

// ---- lowercase substring search (haystack lowercased on the fly) ----
fn char ascii_lower(char c)
{
    if (c >= 'A' && c <= 'Z') return (char)(c - 'A' + 'a');
    return c;
}

fn bool text_contains(char* text, char* needle)
{
    uint tl = ai_strlen(text);
    uint nl = ai_strlen(needle);
    if (nl == 0) return false;
    for (uint i = 0; i + nl <= tl; i++)
    {
        bool match = true;
        for (uint j = 0; j < nl; j++)
        {
            if (ascii_lower(text[i + j]) != ascii_lower(needle[j])) { match = false; break; }
        }
        if (match) return true;
    }
    return false;
}

// find an open window whose title equals `title`
fn int agent_find_window(char* title)
{
    for (int i = 0; i < WIN_MAX; i++)
    {
        if (xk_ws[i].open && ai_streq(&xk_ws[i].title[0], title)) return i;
    }
    return -1;
}

// open a fresh demo/clock window (only if none with that title is open)
fn int agent_open_window(char* kind)
{
    char* title = null;
    if (ai_streq(kind, "clock")) { title = &title_clock[0]; }
    else if (ai_streq(kind, "demo")) { title = &title_demo[0]; }
    else { return -1; }
    if (agent_find_window(title) >= 0) return 1;      // already open
    int c = wm_alloc();
    if (c < 0) return -1;
    xk_ws[c].x = 60; xk_ws[c].y = 320;
    if (ai_streq(kind, "clock"))
    {
        xk_ws[c].w = CLK_W; xk_ws[c].h = CLK_H;
        xk_ws[c].draw = &app_clock_draw; xk_ws[c].key = null;
    }
    else
    {
        xk_ws[c].w = DEMO_W; xk_ws[c].h = DEMO_H;
        xk_ws[c].draw = &app_demo_draw; xk_ws[c].key = null;
    }
    xmcopy(title, &xk_ws[c].title[0]);
    wm_composite();
    wm_present_all();
    return 0;
}

fn int agent_close_window(char* title)
{
    int i = agent_find_window(title);
    if (i < 0) return 1;
    xk_ws[i].open = false;
    wm_composite();
    wm_present_all();
    return 0;
}

fn int agent_focus_window(char* title)
{
    int i = agent_find_window(title);
    if (i < 0) return 1;
    wm_to_front(i);
    wm_composite();
    wm_present_all();
    return 0;
}

// ---- safe action grammar: interpret a model response into ONE action ----
fn void agent_act(char* text)
{
    bool acted = false;
    if (text_contains(text, "open clock"))
    {
        int r = agent_open_window("clock");
        journal_add("open", "clock", r == 0 ? "ok" : (r == 1 ? "already open" : "full"));
        acted = true;
    }
    else if (text_contains(text, "open demo"))
    {
        int r = agent_open_window("demo");
        journal_add("open", "demo", r == 0 ? "ok" : (r == 1 ? "already open" : "full"));
        acted = true;
    }
    else if (text_contains(text, "close clock"))
    {
        int r = agent_close_window(&title_clock[0]);
        journal_add("close", "clock", r == 0 ? "ok" : "not open");
        acted = true;
    }
    else if (text_contains(text, "close demo"))
    {
        int r = agent_close_window(&title_demo[0]);
        journal_add("close", "demo", r == 0 ? "ok" : "not open");
        acted = true;
    }
    else if (text_contains(text, "close chat"))
    {
        int r = agent_close_window(&title_chat[0]);
        journal_add("close", "chat", r == 0 ? "ok" : "not open");
        acted = true;
    }
    else if (text_contains(text, "focus clock"))
    {
        int r = agent_focus_window(&title_clock[0]);
        journal_add("focus", "clock", r == 0 ? "ok" : "not open");
        acted = true;
    }
    else if (text_contains(text, "focus chat"))
    {
        int r = agent_focus_window(&title_chat[0]);
        journal_add("focus", "chat", r == 0 ? "ok" : "not open");
        acted = true;
    }
    else if (text_contains(text, "focus terminal"))
    {
        int r = agent_focus_window(&title_term[0]);
        journal_add("focus", "terminal", r == 0 ? "ok" : "not open");
        acted = true;
    }
    if (!acted)
    {
        journal_add("none", "no actionable intent", "ignored");
    }
}