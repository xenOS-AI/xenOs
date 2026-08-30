module xk;

// ============================================================================
// xenOS chat box app: a WM window with a scrollback of user/assistant turns,
// a single-line text input, and a send path through the provider-agnostic AI
// client (ai_chat). Until the network transport lands it answers via the mock
// transport, so the whole client pipeline is exercisable in the GUI.
// ============================================================================

const int CHAT_W = 620;
const int CHAT_H = 300;
const int CHAT_STRIP = 150;        // height of the bottom chat window (auto-tiled)
const int CHAT_LINES = 26;         // scrollback capacity
const int CHAT_LINELEN = 120;
const int CHAT_INPUTLEN = 96;

struct ChatLine
{
    char[CHAT_LINELEN] text;
    uint color;                    // rendering colour for this line
}
ChatLine[CHAT_LINES] chat_lines;   // ring: chat_lines[chat_head % CHAT_LINES]
int chat_count;                    // total lines ever written
int chat_view_top;                 // index of the top visible line (0 = scroll to top)
char[CHAT_INPUTLEN] chat_input;
int chat_in_len;
bool chat_busy;                    // waiting for a reply (input still allowed)
char[AI_CONTENTLEN] chat_pending_prompt; // prompt being answered

const uint COL_USER      = 0x7FC8FF;
const uint COL_ASSISTANT = 0xE8E4D8;
const uint COL_SYS       = 0xF0B060;
const uint COL_INPUT     = 0xFFFFFF;

// return index of the i-th newest line (0 = newest)
fn int chat_line_idx(int back)
{
    int n = chat_count;
    int idx = n - 1 - back;             // global line number (0 = first ever)
    if (idx < 0) return -1;
    return idx % CHAT_LINES;            // slot in the ring
}

fn void chat_push(char* text, uint color)
{
    char[CHAT_LINELEN] t;
    ai_strcpy(&t[0], text);
    // truncate to fit
    ChatLine* slot = &chat_lines[chat_count % CHAT_LINES];
    ai_strcpy(&slot.text[0], &t[0]);
    slot.color = color;
    chat_count++;
    // keep the view pinned to the bottom (newest) unless the user scrolled up
    chat_view_top = chat_count - CHAT_LINES;
    if (chat_view_top < 0) chat_view_top = 0;
}

fn void chat_system(char* text)
{
    chat_push(text, COL_SYS);
}

fn void app_chat_draw(Window* w)
{
    int ox = w.x + 6;
    int oy = w.y + TITLE_H + 4;
    int area_h = w.h - TITLE_H - 8 - 16;   // room for one input line at the bottom
    int rows = area_h / 8;
    if (rows > CHAT_LINES) rows = CHAT_LINES;

    // scrollback
    for (int r = 0; r < rows; r++)
    {
        int visible_line = chat_view_top + r;
        int y = oy + r * 8;
        if (visible_line < 0 || visible_line >= chat_count) continue;
        ChatLine* l = &chat_lines[visible_line % CHAT_LINES];
        fb_textn(ox, y, &l.text[0], (int)ai_strlen(&l.text[0]), l.color, fb_rgb(20, 22, 28));
    }
    // input line box at the bottom
    int iny = w.y + TITLE_H + 4 + rows * 8;
    fb_fill_rect(w.x + 2, iny, w.w - 4, 16, fb_rgb(8, 10, 14));
    fb_textn(w.x + 4, iny + 4, ">", 1, COL_INPUT, fb_rgb(8, 10, 14));
    if (chat_in_len > 0)
    {
        fb_textn(w.x + 4 + 8, iny + 4, &chat_input[0], chat_in_len, COL_INPUT, fb_rgb(8, 10, 14));
    }
}

fn void app_chat_send()
{
    if (chat_in_len == 0) return;
    char[CHAT_INPUTLEN] prompt;
    ai_strcpy(&prompt[0], &chat_input[0]);
    // echo the user turn in blue
    chat_push(&prompt[0], COL_USER);
    chat_in_len = 0;
    chat_input[0] = 0;

    AiChatResult res;
    int rc = ai_chat(&prompt[0], &res);
    if (rc == -2)
    {
        chat_system("(AI not configured: set model/endpoint/token in AI.CFG)");
    }
    else if (rc != 0)
    {
        chat_system("(AI transport error)");
    }
    else if (!res.ok || res.content[0] == 0)
    {
        chat_system("(no reply)");
    }
    else
    {
        chat_push(&res.content[0], COL_ASSISTANT);
    }
}

fn void app_chat_key(Window* w, char c)
{
    (void)w;
    if (c == '\n' || c == '\r')
    {
        app_chat_send();
    }
    else if (c == 0x08)
    {
        if (chat_in_len > 0)
        {
            chat_in_len--;
            chat_input[chat_in_len] = 0;
        }
    }
    else if (c >= 0x20 && c <= 0x7E)
    {
        if (chat_in_len < CHAT_INPUTLEN - 1)
        {
            chat_input[chat_in_len++] = c;
            chat_input[chat_in_len] = 0;
        }
    }
}

// Scroll the view up / down by delta lines (mouse wheel could be wired here).
fn void app_chat_scroll(int delta)
{
    int newtop = chat_view_top + delta;
    if (newtop < 0) newtop = 0;
    if (newtop > chat_count - CHAT_LINES) newtop = chat_count - CHAT_LINES;
    if (newtop < 0) newtop = 0;
    chat_view_top = newtop;
}

fn void chat_open_window()
{
    int c = wm_alloc();
    if (c < 0) return;
    int margin = WIN_MARGIN;
    int gap    = WIN_GAP;
    // full-width strip sitting on the dock, above the terminal area
    xk_ws[c].x = margin;
    xk_ws[c].y = g_fb_h - DOCK_H - gap - CHAT_STRIP;
    xk_ws[c].w = g_fb_w - margin * 2;
    xk_ws[c].h = CHAT_STRIP;
    xk_ws[c].draw = &app_chat_draw;
    xk_ws[c].key = &app_chat_key;
    xmcopy(&title_chat[0], &xk_ws[c].title[0]);
    chat_push("Welcome to xenOS Chat. Ask anything; replies come from the ", COL_SYS);
    chat_push("provider through the in-kernel AI client.", COL_SYS);
    wm_composite();
    wm_present_all();
}

char[22] title_chat = {'C','h','a','t',0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};