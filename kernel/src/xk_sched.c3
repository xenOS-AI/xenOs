module xk;

// ============================================================================
// xenOS cooperative round-robin scheduler + kernel threads.
// The CPU is shared on voluntary yields (thread_yield). Task 0 is the boot/WM
// context; spawned tasks get dedicated stacks with crafted callee-saved frames.
// (A preemptive iretq-based variant was attempted but hit a subtle QEMU/RSP
// interaction; cooperative switching is reliable and is the shipped scheduler.)
// ============================================================================

const int   MAX_TASKS     = 8;
const ulong TASK_STACK_SZ = 16384;
const ulong STACKS_BASE   = 0x3000000;

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

fn void thread_init()
{
    g_tasks[0].used = true;
    g_tasks[0].pid  = 0;
    g_tasks[0].saved_sp = 0;
    g_current = 0;
    g_next_pid = 1;
}

// Create a task that will run `entry` on its own dedicated stack (not returned).
fn int thread_create(TaskFn entry, char* name)
{
    for (int i = 0; i < MAX_TASKS; i++)
    {
        if (!g_tasks[i].used)
        {
            ulong base = STACKS_BASE + (ulong)i * TASK_STACK_SZ;
            ulong* sp  = (ulong*)(base + TASK_STACK_SZ);
            sp -= 7;                    // [0]..[5] = r15..rbx ; [6] = ret (entry)
            sp[0] = 0; sp[1] = 0; sp[2] = 0;
            sp[3] = 0; sp[4] = 0; sp[5] = 0;
            sp[6] = (ulong)entry;

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

fn int next_run()
{
    for (int i = 1; i <= MAX_TASKS; i++)
    {
        int k = (g_current + i) % MAX_TASKS;
        if (g_tasks[k].used) return k;
    }
    return -1;
}

fn void thread_yield()
{
    int cur = g_current;
    int nxt = next_run();
    if (nxt < 0 || nxt == cur) return;
    g_current = nxt;
    xk_switch(&g_tasks[cur].saved_sp, g_tasks[nxt].saved_sp);
    g_current = cur;            // switched back here; we are `cur` again
}

// ---- demo tasks: interleave via thread_yield in their loop ----
fn void demo_task_a() { int c = 0; for (;;) { c++; thread_yield(); if (c % 500 == 0) { xk_puts("A"); } } }
fn void demo_task_b() { int c = 0; for (;;) { c++; thread_yield(); if (c % 500 == 0) { xk_puts("B"); } } }
fn void demo_task_c() { int c = 0; for (;;) { c++; thread_yield(); if (c % 500 == 0) { xk_puts("C"); } } }

fn void thread_spawn_demos()
{
    thread_create(&demo_task_a, "demo-a");
    thread_create(&demo_task_b, "demo-b");
    thread_create(&demo_task_c, "demo-c");
}