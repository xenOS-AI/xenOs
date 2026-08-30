module xk;

// ============================================================================
// xenOS preemptive round-robin scheduler.
//
// Context-switch strategy (chosen because QEMU 11's iretq rejects hand-crafted
// interrupt frames -- a crafted new-task frame #GPs / lands RSP=0):
//   * NEW tasks are entered COOPERATIVELY via xk_switch (a crafted callee-saved
//     frame; `ret` lands on the entry function). Proven reliable on QEMU.
//   * PREEMPTION is driven by the PIT timer ISR: it saves the current task's
//     REAL interrupt frame (captured by isr_common) into Task.saved_frame, then
//     switches to the next task with xk_switch. When a task is switched back
//     into, the code after xk_switch calls xk_preempt_resume(saved_frame) which
//     iretq's -- and because that frame was created by the CPU on a real
//     ring-0 interrupt, the same-ring iretq behaves correctly under QEMU.
//   * Thus NO hand-crafted frame is ever iretq'd; only real isr_common frames
//     are. All task movement uses the reliable xk_switch / real-frame-iretq pair.
//
// NOTE on task state: because a task is preempted inside a timer ISR and resumed
// via a chain of xk_switch + xk_preempt_resume (iretq to its real frame), a
// task's OWN stack locals do not reliably persist across preemption points.
// State that must survive across a task's time slices lives in module globals
// (see the demo tasks below -- the per-task "last second" marker is a global).
//
// Round-robin: the timer preempts on every tick when more than one task is
// runnable, so each task gets a ~10 ms time slice at 100 Hz.
// ============================================================================

const int   MAX_TASKS     = 8;
const ulong TASK_STACK_SZ = 16384;
const ulong STACKS_BASE   = 0x3000000;

// Cooperative xk_switch frame layout (see asm_runtime.asm): [0..4]=r15,r14,r13,
// r12,rbp [5]=rbx [6]=return address. A NEW task's return address is its entry.
const int SWITCH_QWORDS = 7;

alias TaskFn = fn void();

struct Task
{
    bool  used;
    int   pid;
    char[16] name;
    ulong saved_sp;         // cooperative callee-saved context pointer (xk_switch)
    ulong saved_frame;      // REAL isr_common interrupt frame to resume via iretq
}

Task[MAX_TASKS] g_tasks;
int g_current;              // index of the currently running task
int g_next_pid;
bool g_preempt_ready;       // set once the desktop/ring-3 boundary is past

extern fn void xk_switch(ulong* cur_slot, ulong new_sp);
extern fn void xk_preempt_resume(ulong frame);
extern fn ulong xk_get_ticks();
// xk_eoi / xk_sti are module-level fns (defined in xk_intr.c3 / xk_core.c3).

fn void thread_init()
{
    g_tasks[0].used = true;
    g_tasks[0].pid  = 0;
    g_tasks[0].saved_sp = 0;        // filled on the first preemption of the boot/WM task
    g_tasks[0].saved_frame = 0;
    g_current = 0;
    g_next_pid = 1;
    g_preempt_ready = false;
}

// Create a task that will run `entry` on its own dedicated kernel stack.
// `entry` must not return. The initial context is a cooperative callee-saved
// frame: xk_switch will `ret` into `entry` on the first time the task runs.
fn int thread_create(TaskFn entry, char* name)
{
    for (int i = 0; i < MAX_TASKS; i++)
    {
        if (!g_tasks[i].used)
        {
            ulong base = STACKS_BASE + (ulong)i * TASK_STACK_SZ;
            ulong* sp  = (ulong*)(base + TASK_STACK_SZ);
            sp -= SWITCH_QWORDS;            // [0..5] = r15..rbx ; [6] = ret (entry)
            sp[0] = 0; sp[1] = 0; sp[2] = 0;
            sp[3] = 0; sp[4] = 0; sp[5] = 0;
            sp[6] = (ulong)entry;

            g_tasks[i].used = true;
            g_tasks[i].pid  = g_next_pid++;
            g_tasks[i].saved_sp = (ulong)sp;
            g_tasks[i].saved_frame = 0;
            for (int n = 0; n < 16 && name[n] != 0; n++)
            {
                g_tasks[i].name[n] = name[n];
            }
            g_tasks[i].name[15] = 0;
            return i;
        }
    }
    return -1;
}

// Round-robin: the next used task strictly after the current one (wraps).
fn int next_run()
{
    for (int i = 1; i <= MAX_TASKS; i++)
    {
        int k = (g_current + i) % MAX_TASKS;
        if (g_tasks[k].used) return k;
    }
    return -1;
}

// Called from the PIT timer ISR (irq_timer) on every tick. If preemption is
// enabled and another task is runnable: acknowledge the PIC, save the CURRENT
// task's REAL interrupt frame, then xk_switch to the next task. When this task
// later gets the CPU back (xk_switch returns here), iretq its saved real frame.
fn void sched_timer(IntFrame* f)
{
    if (!g_preempt_ready) return;
    int nxt = next_run();
    if (nxt < 0 || nxt == g_current) return;
    int cur = g_current;
    g_tasks[cur].saved_frame = (ulong)f;    // real frame alive on cur's stack
    g_current = nxt;
    xk_eoi(0);                              // ACK the timer before we leave
    xk_switch(&g_tasks[cur].saved_sp, g_tasks[nxt].saved_sp);
    // ---- resumed here when `cur` is scheduled again ----
    ulong fr = g_tasks[cur].saved_frame;
    if (fr != 0)
    {
        g_tasks[cur].saved_frame = 0;
        xk_preempt_resume(fr);              // iretq to cur's real frame; never returns
    }
    // fr == 0 should not happen for a preempted task; fall through as a no-op
}

// Voluntary yield: give up the current time slice by sleeping on the next
// timer tick (the timer then preempts us via sched_timer).
fn void thread_yield()
{
    xk_hlt();
}

// ---- demo tasks: BUSY loops with NO yield, proving the timer really
//      preempts the CPU (without preemption these would starve the desktop
//      and never print after the first second). xk_sti() on entry so a task
//      runs with interrupts enabled and gets its own time slice. Each prints
//      its letter once per second of wall-clock (driven by the global tick
//      counter). The "last second" marker is a module GLOBAL: a task's stack
//      locals do not survive the xk_switch+iretq resume (see header note).
int g_last_sec_a = -1;
int g_last_sec_b = -1;
int g_last_sec_c = -1;
// The tick counter MUST be read through xk_get_ticks() (an asm call), NOT
// directly from g_ticks: a direct read lets the C3 compiler hoist g_ticks/100
// out of the busy loop as a loop-invariant, so the per-second print never fires.
// The trailing xk_hlt() paces each task off the PIT instead of pinning a core:
// without it these infinite loops hog the whole CPU and starve the desktop
// loop (mouse cursor / compositor), which only advances its own idle loop.
fn void demo_task_a() { xk_sti(); for (;;) { int t = (int)(xk_get_ticks() / 100); if (t != g_last_sec_a) { g_last_sec_a = t; xk_puts("A"); } xk_hlt(); } }
fn void demo_task_b() { xk_sti(); for (;;) { int t = (int)(xk_get_ticks() / 100); if (t != g_last_sec_b) { g_last_sec_b = t; xk_puts("B"); } xk_hlt(); } }
fn void demo_task_c() { xk_sti(); for (;;) { int t = (int)(xk_get_ticks() / 100); if (t != g_last_sec_c) { g_last_sec_c = t; xk_puts("C"); } xk_hlt(); } }

fn void thread_spawn_demos()
{
    thread_create(&demo_task_a, "demo-a");
    thread_create(&demo_task_b, "demo-b");
    thread_create(&demo_task_c, "demo-c");
}

// Enable preemption once the desktop loop is running (after the ring-3 demo).
fn void sched_enable()
{
    g_preempt_ready = true;
}