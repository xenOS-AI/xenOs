module xk;

// ============================================================================
// xenOS physical page-frame allocator + a simple first-fit kernel heap.
// The heap lives in a fixed contiguous reserved region (no fragmentation risk
// from non-contiguous growth). Blocks are contiguous, each preceded by a
// 16-byte header { ulong payload_size; ulong used; }; stride = 16 + payload.
// ============================================================================

const ulong FRAME_SZ   = 4096;
const ulong MEM_START  = 0x00100000;   // 1 MiB: below this is BIOS/boot data
const ulong MEM_END    = 0x06000000;   // 96 MiB (matches BootInfo mem_mb)

const uint BM_BYTES    = (uint)((MEM_END - MEM_START) / FRAME_SZ / 8);
char[BM_BYTES] frame_bitmap;

uint g_total_frames;
uint g_used_frames;

fn uint frame_idx(ulong addr)       { return (uint)((addr - MEM_START) / FRAME_SZ); }
fn bool frame_bit(uint idx)         { return ((frame_bitmap[idx >> 3] >> (idx & 7)) & (char)1) != (char)0; }
fn void frame_set(uint idx)         { frame_bitmap[idx >> 3] |= (char)(1 << (idx & 7)); }
fn void frame_clr(uint idx)         { frame_bitmap[idx >> 3] &= (char)~(1 << (idx & 7)); }

fn void frame_mark_range(ulong start, ulong end)
{
    for (ulong a = start; a < end && a < MEM_END; a += FRAME_SZ)
    {
        frame_set(frame_idx(a));
    }
}

fn void frame_init()
{
    for (uint i = 0; i < BM_BYTES; i++) { frame_bitmap[i] = (char)0; }
    g_total_frames = (uint)((MEM_END - MEM_START) / FRAME_SZ);
    frame_mark_range(MEM_START, xk_get_bss_end());                       // kernel image
    frame_mark_range(LX_USER_START, LX_HEAP_END);                        // Linux process identity code+heap pages
    frame_mark_range(SHADOW, SHADOW + (ulong)FB_W_MAX * (ulong)FB_H_MAX * 4); // shadow buffer
    frame_mark_range(STACKS_BASE, STACKS_BASE + (ulong)MAX_TASKS * TASK_STACK_SZ); // threads
    frame_mark_range(HEAP_BASE, HEAP_BASE + HEAP_TOTAL);                 // kernel heap
    g_used_frames = 0;
    for (uint i = 0; i < g_total_frames; i++) { if (frame_bit(i)) g_used_frames++; }
}

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

// ==================== kernel heap (first-fit, splitting + next-coalescing) ==
const ulong HDR_SZ   = 16;
const ulong HEAP_BASE  = 0x01000000;   // 16 MiB (below the shadow buffer)
const ulong HEAP_TOTAL = 0x00200000;   // 2 MiB reserved heap
const ulong HEAP_MIN   = 24;

ulong heap_bytes_in_use;

fn ulong blk_size(ulong p)    { return *(ulong*)p; }
fn bool  blk_used(ulong p)    { return (*(ulong*)(p + 8)) != 0; }
fn void blk_set(ulong addr, ulong nbytes, int flag) { *(ulong*)addr = nbytes; *(ulong*)(addr + 8) = (ulong)flag; }
fn ulong blk_next(ulong p)    { return p + HDR_SZ + blk_size(p); }

fn void heap_init()
{
    // the whole 2 MiB region starts as one free block
    blk_set(HEAP_BASE, HEAP_TOTAL - HDR_SZ, 0);
    heap_bytes_in_use = 0;
}

fn void* kmalloc(ulong n)
{
    ulong want = (n + 7) & ~((ulong)7);
    if (want < HEAP_MIN) want = HEAP_MIN;
    ulong end = HEAP_BASE + HEAP_TOTAL;
    ulong p = HEAP_BASE;
    while (p + HDR_SZ <= end && blk_size(p) != 0)
    {
        if (!blk_used(p) && blk_size(p) >= want)
        {
            ulong leftover = blk_size(p) - want;
            if (leftover >= HDR_SZ + HEAP_MIN)
            {
                blk_set(p + HDR_SZ + want, leftover, 0);   // split the tail off
                blk_set(p, want, 1);
            }
            else
            {
                blk_set(p, want, 1);                         // take the whole block
            }
            heap_bytes_in_use += want;
            return (void*)(p + HDR_SZ);
        }
        p = blk_next(p);
    }
    return null;                       // heap exhausted
}

fn void kfree(void* ptr)
{
    if (ptr == null) return;
    ulong p = (ulong)ptr - HDR_SZ;
    if (p < HEAP_BASE || p + HDR_SZ > HEAP_BASE + HEAP_TOTAL) return;
    heap_bytes_in_use -= blk_size(p);
    blk_set(p, blk_size(p), 0);
    // coalesce with the next block when both are free
    ulong nx = blk_next(p);
    if (nx + HDR_SZ <= HEAP_BASE + HEAP_TOTAL && blk_size(nx) != 0 && !blk_used(nx))
    {
        blk_set(p, blk_size(p) + HDR_SZ + blk_size(nx), 0);
    }
}