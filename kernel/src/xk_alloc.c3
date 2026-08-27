module xk;

// ============================================================================
// xenOS physical page-frame allocator.
// A bitmap over physical RAM [MEM_START, MEM_END) at 4 KiB granularity.
// The regions the kernel already occupies (low memory, kernel image, shadow
// framebuffer, task stacks) are marked used at init.
// ============================================================================

const ulong FRAME_SZ   = 4096;
const ulong MEM_START  = 0x00100000;   // 1 MiB: below this is BIOS/boot data
const ulong MEM_END    = 0x06000000;   // 96 MiB (matches BootInfo mem_mb)

// bitmap is sized in BSS: (MEM_END-MEM_START)/4096 bits
const uint BM_BYTES    = (uint)((MEM_END - MEM_START) / FRAME_SZ / 8);
char[BM_BYTES] frame_bitmap;

uint g_total_frames;
uint g_used_frames;

fn uint frame_idx(ulong addr)
{
    return (uint)((addr - MEM_START) / FRAME_SZ);
}

fn bool frame_bit(uint idx)
{
    return ((frame_bitmap[idx >> 3] >> (idx & 7)) & (char)1) != (char)0;
}

fn void frame_set(uint idx)
{
    frame_bitmap[idx >> 3] |= (char)(1 << (idx & 7));
}

fn void frame_clr(uint idx)
{
    frame_bitmap[idx >> 3] &= (char)~(1 << (idx & 7));
}

fn void frame_mark_range(ulong start, ulong end)
{
    for (ulong a = start; a < end && a < MEM_END; a += FRAME_SZ)
    {
        frame_set(frame_idx(a));
    }
}

fn void frame_init()
{
    for (uint i = 0; i < BM_BYTES; i++)
    {
        frame_bitmap[i] = (char)0;
    }
    g_total_frames = (uint)((MEM_END - MEM_START) / FRAME_SZ);
    g_used_frames = 0;

    // mark pages the OS already owns as used
    frame_mark_range(MEM_START, xk_get_bss_end());              // kernel image
    frame_mark_range(SHADOW, SHADOW + FB_W * FB_H * 4);        // shadow buffer
    frame_mark_range(STACKS_BASE, STACKS_BASE + (ulong)MAX_TASKS * TASK_STACK_SZ); // task stacks

    // count
    g_used_frames = 0;
    for (uint i = 0; i < g_total_frames; i++)
    {
        if (frame_bit(i)) g_used_frames++;
    }
}

// Allocate one 4 KiB frame; returns 0 if none free.
fn ulong frame_alloc()
{
    for (uint i = 0; i < g_total_frames; i++)
    {
        if (!frame_bit(i))
        {
            frame_set(i);
            g_used_frames++;
            return MEM_START + (ulong)i * FRAME_SZ;
        }
    }
    return 0;
}

// Free a frame previously handed out by frame_alloc().
fn void frame_free(ulong addr)
{
    if (addr < MEM_START || addr >= MEM_END) return;
    uint idx = frame_idx(addr);
    if (frame_bit(idx))
    {
        frame_clr(idx);
        g_used_frames--;
    }
}