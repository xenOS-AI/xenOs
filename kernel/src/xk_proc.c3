module xk;

// ============================================================================
// xenOS per-process management (Phase A.1)
// Extends the single-process Linux userland into a multi-process system with
// distinct CR3 per process, per-process fd tables, and integration with the
// preemptive scheduler.
// ============================================================================

const int MAX_PROCS = 16;
const int MAX_PROC_FDS = 32;  // per-process fd table size

// Process state (mirrors the globals that lived in xk_linux.c3)
struct Proc
{
    bool used;
    int pid;
    int ppid;
    int state;  // 0=running, 1=exited, 2=zombie
    int exit_status;
    
    // Address space
    ulong cr3;              // per-process page table root
    ulong brk;              // program break
    ulong mmap_cur;         // next anonymous mmap address
    ulong map_end;          // high-water mark of mapped regions
    
    // Thread ID for TLS (generalized from single g_tid_addr)
    ulong tid_addr;
    
    // Saved context for fork/resume
    ulong saved_parent_cr3;
    ulong saved_parent_brk;
    ulong saved_parent_mmap;
    ulong saved_parent_pid;
    ulong saved_parent_rcx;
    ulong saved_parent_r11;
    ulong saved_parent_user_rsp;
    ulong[12] saved_parent_resume_regs;  // {a1..a6, rbx,rbp,r12..r15}
}

Proc[MAX_PROCS] g_procs;
int[MAX_PROCS][MAX_PROC_FDS] g_proc_fds;  // separate fd table per process
int g_current_proc = 0;     // index of currently running Linux process
int g_next_proc_pid = 2;    // pid 1 is the first process

// Initialize the process table
fn void proc_init()
{
    for (int i = 0; i < MAX_PROCS; i++)
    {
        g_procs[i].used = false;
        g_procs[i].pid = 0;
        g_procs[i].ppid = 0;
        g_procs[i].state = 0;
        g_procs[i].exit_status = 0;
        g_procs[i].cr3 = 0;
        g_procs[i].brk = 0;
        g_procs[i].mmap_cur = 0;
        g_procs[i].map_end = 0;
        g_procs[i].tid_addr = 0;
        for (int j = 0; j < MAX_PROC_FDS; j++)
        {
            g_proc_fds[i][j] = -1;
        }
    }
    
    // Mark process 0 as the initial process (migrate existing globals)
    // Phase A.1: for now, don't migrate - just init the process table
    g_procs[0].used = true;
    g_procs[0].pid = 1;
    g_procs[0].ppid = 0;
    g_procs[0].state = 0;  // running
    g_procs[0].cr3 = 0;  // will be set when switching
    g_procs[0].brk = 0;
    g_procs[0].mmap_cur = 0;
    g_procs[0].map_end = 0;
    g_procs[0].tid_addr = 0;
    
    // Initialize fd table for process 0 (assume ownership of existing global fds)
    // This is a simplification - in reality we'd need to track ownership properly
    for (int j = 0; j < MAX_PROC_FDS; j++)
    {
        g_proc_fds[0][j] = j;  // process 0 owns all global fds initially
    }
    
    g_current_proc = 0;
    g_next_proc_pid = 2;
    
    xk_puts("[proc] process table initialized, pid 1 running\n");
}

// Allocate a new process structure
fn int proc_alloc()
{
    for (int i = 0; i < MAX_PROCS; i++)
    {
        if (!g_procs[i].used)
        {
            g_procs[i].used = true;
            g_procs[i].pid = g_next_proc_pid++;
            g_procs[i].ppid = g_procs[g_current_proc].pid;
            g_procs[i].state = 0;  // running
            g_procs[i].cr3 = 0;
            g_procs[i].brk = 0;
            g_procs[i].mmap_cur = 0;
            g_procs[i].map_end = 0;
            g_procs[i].tid_addr = 0;
            g_procs[i].exit_status = 0;
            for (int j = 0; j < MAX_PROC_FDS; j++)
            {
                g_proc_fds[i][j] = -1;
            }
            return i;
        }
    }
    return -1;  // no free process slots
}

// Switch to a different process (load its CR3 and restore its state)
fn void proc_switch(int proc_idx)
{
    if (proc_idx < 0 || proc_idx >= MAX_PROCS || !g_procs[proc_idx].used)
    {
        return;
    }
    
    // Phase A.1: for now, just switch the current process index
    // Full CR3 switching will be added in later phases
    g_current_proc = proc_idx;
    
    xk_puts("[proc] switched to pid ");
    xk_putdec(g_procs[proc_idx].pid);
    xk_puts("\n");
}

// Get the current process structure
fn Proc proc_current()
{
    return g_procs[g_current_proc];
}

// Find a process by PID
fn int proc_find_by_pid(int pid)
{
    for (int i = 0; i < MAX_PROCS; i++)
    {
        if (g_procs[i].used && g_procs[i].pid == pid)
        {
            return i;
        }
    }
    return -1;
}

// Mark a process as exited
fn void proc_exit(int status)
{
    Proc p = proc_current();
    p.state = 1;  // exited
    p.exit_status = status;
    g_procs[g_current_proc] = p;
    
    xk_puts("[proc] pid ");
    xk_putdec(p.pid);
    xk_puts(" exited with status ");
    xk_putdec(status);
    xk_puts("\n");
}

// Reap a zombie process (called by waitpid)
fn int proc_reap(int pid, int* status)
{
    int idx = proc_find_by_pid(pid);
    if (idx < 0) return -1;
    
    Proc p = g_procs[idx];
    if (p.state != 1) return -1;  // not exited
    
    if (status != null)
    {
        *status = p.exit_status;
    }
    
    // Free the process slot
    g_procs[idx].used = false;
    // TODO: free CR3 page tables and associated memory
    
    return 0;
}
