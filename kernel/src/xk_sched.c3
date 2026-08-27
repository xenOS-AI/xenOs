module xk;

// ============================================================================
// xenOS cooperative round-robin scheduler + kernel threads ("tasks").
// The CPU is shared on voluntary yields.  Task 0 is reserved for the boot
// context (the display/WM "main" task); spawned tasks get dedicated stacks.
// ============================================================================

const int  MAX_TASKS = 8;
const ulong TASK_STACK_SZ = 16384;

// Fixed stack pool far above kernel / shadow framebuffer (48 MiB).
const ulong STACKS_BASE = 0x3000000;

struct Task
{
    bool  used;
    int   pid;
    char[16] name;
    ulong saved_sp;         // rsp of the last switch-away / crafted frame
}

Task[MAX_TASKS] g_tasks;
int g_current;              // index of the currently running task
int g_next_pid;

alias TaskFn = fn void();
extern fn void xk_switch(ulong* cur_slot, ulong new_sp);

// Mark the boot context as task slot 0 (the "main" task).
fn void thread_init()
{
    g_tasks[0].used = true;
    g_tasks[0].pid  = 0;
    g_tasks[0].saved_sp = 0;
    g_current = 0;
    g_next_pid = 1;
}

// Create a task that will run `entry` on its own dedicated stack.
// `entry` must not return (loop forever or exit via abort).
fn int thread_create(TaskFn entry, char* name)
{
    for (int i = 0; i < MAX_TASKS; i++)
    {
        if (!g_tasks[i].used)
        {
            ulong base = STACKS_BASE + (ulong)i * TASK_STACK_SZ;
            ulong* sp  = (ulong*)(base + TASK_STACK_SZ);
            // Craft a fake saved-context frame (see xk_switch layout):
            //   [0]..[5] = r15,r14,r13,r12,rbp,rbx  ; [6] = return (entry)
            sp -= 7;
            sp[0] = 0;              // r15
            sp[1] = 0;              // r14
            sp[2] = 0;              // r13
            sp[3] = 0;              // r12
            sp[4] = 0;              // rbp
            sp[5] = 0;              // rbx
            sp[6] = (ulong)entry;   // first `ret` lands on the task entry

            g_tasks[i].used = true;
            g_tasks[i].pid  = g_next_pid++;
            g_tasks[i].saved_sp = (ulong)sp;
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

// Voluntarily give up the CPU to the next runnable task.
fn void thread_yield()
{
    int cur = g_current;
    int nxt = next_run();
    if (nxt < 0 || nxt == cur) return;
    g_current = nxt;
    xk_switch(&g_tasks[cur].saved_sp, g_tasks[nxt].saved_sp);
    g_current = cur;            // switched back here; we are `cur` again
}

// Remove the calling task so that only main remains.
fn void thread_exit()
{
    xk_puts("[sched] task exit (not yet implemented)\r\n");
    for (;;) thread_yield();
}

// ---- demo tasks: prove round-robin multitasking on the serial console ----
fn void demo_task_a() { int c = 0; for (;;) { c++; thread_yield(); if (c % 100 == 0) { xk_puts("A"); } } }
fn void demo_task_b() { int c = 0; for (;;) { c++; thread_yield(); if (c % 100 == 0) { xk_puts("B"); } } }
fn void demo_task_c() { int c = 0; for (;;) { c++; thread_yield(); if (c % 100 == 0) { xk_puts("C"); } } }

fn void thread_spawn_demos()
{
    thread_create(&demo_task_a, "demo-a");
    thread_create(&demo_task_b, "demo-b");
    thread_create(&demo_task_c, "demo-c");
}