# AGENTS.md — xenOS Durable Handoff for the Next AI Agent

## Project

**xenOS** is a from‑scratch hobby operating system written entirely in C3 (a custom kernel). It boots from a 512-byte BIOS boot sector into a freestanding kernel, then runs a graphical desktop (X11/Wayland‑style) with a shell, userspace tools, and an emerging AI/agent subsystem.

### Goals
- A fully hand-written kernel (no borrowed code) that boots in QEMU.
- Real hardware drivers (ATA, AHCI, PCI, PS/2 keyboard/mouse, VESA framebuffer).
- A desktop environment: window manager + compositor + apps (terminal, clock, demo).
- Userspace: cross-built musl Linux ELFs (static + dynamic), real ELF loader, POSIX syscalls.
- Networking: e1000 Ethernet + ARP + IPv4 + TCP + HTTP + TLS from scratch.
- AI/agent path: AI configuration, client, chat, agent orchestration modules.
- Desktop environment: Xfce 4.18 + Xwayland cross-built and staged.

### Current Working State (as of 2026‑09‑06)
- **Booting**: Verified under QEMU TCG — boots to graphical desktop with window manager, terminal, clock, demo windows.
- **Kernel**: Scheduler (cooperative round‑robin + preemptive timer), memory manager (frame allocator + kmalloc heap), interrupt/DMA/PIC/PIT, PCI/AHCI, FAT16 + ext4 (read‑only), VESA framebuffer + shadow + dirty‑rect blit, 8×8 font, PS/2 keyboard/mouse, TSS/ring‑3 userland with per‑process CR3, syscall `int 0x80` gate.
- **Userspace**: Linux ELF loader (static + dynamic), AF_UNIX sockets, epoll, eventfd, /dev/shm, MAP_SHARED anonymous mmap, ioctl, fork (synchronous child‑first), file‑backed mmap for .so loading. Dynamic GTK app (dynmain) runs in‑guest against shared musl .so tree staged on ext4 rootfs.
- **GUI**: Wayland compositor (xk_wl.c3) — stock libwayland‑client renders to framebuffer via SHM; XWayland cross‑built; Xfce 4.18 cross‑built; runtime staged on rootfs.
- **Networking**: e1000 NIC driver, ARP, IPv4, TCP client, HTTP/1.1, TLS 1.2 (SHA‑256, HMAC, AES‑GCM, ECDHE‑RSA, P‑256). Boot‑time self‑tests pass. Host mock AI provider works (ARP → TCP → HTTP → mock).
- **AI modules**: xk_ai_cfg.c3, xk_ai_client.c3, xk_chat.c3, xk_agent.c3 exist but are mostly stubs/mocks; real AI integration incomplete.
- **Build**: `./build.sh` produces `build/xenos.img` + `build/xenos.iso` (if xorrisofs). `./run.sh` boots GUI; `./run.sh serial` for headless.

### Incomplete / Experimental
- **AHCI DMA** — link up, DET=3, DHRS asserts, but sector data DMA path returns zeroed buffers (the known remaining piece of the AHCI driver).
- **AI/agent** — modules are skeleton/stub; no real remote AI integration yet.
- **Multi‑process** — one ring‑3 process at a time; no fork/exec table.
- **Xfce runtime** — staged but not fully exercised end‑to‑end (desktop boot verified by screenshot, not by interactive test).
- **Serial console fallback** — used when FAT16 not mounted; not a production path.

## Architecture

### Layers

| Layer | Location | Responsibility |
|-------|----------|----------------|
| **Boot** | `boot/stage1.asm`, `boot/stage2.asm`, `iso/iso_boot.asm` | Real‑mode boot sector → long‑mode trampoline → kernel load → entry |
| **Kernel** | `kernel/src/*.c3` | Scheduling, memory, interrupts, devices, filesystems, networking, graphics |
| **Ring‑3 userspace** | `user/sys_prog.asm`, `xk_*.c3` | Shell, apps, chat, AI modules, dynamic ELF loader |
| **Host tools** | `tools/*.c3` | Build scripts (`mkdisk`, `mkbin`, `mkbootimg`, `mkfat`), font gen, protocol/self‑tests |
| **Build orchestration** | `build.sh`, `scripts/*.sh` | Compile freestanding components, stage filesystems, verify QEMU boot |

### Major Subsystems

| Subsystem | Module(s) | Responsibility |
|-----------|-----------|----------------|
| **Boot** | `boot/stage1.asm`, `boot/stage2.asm` | Real‑mode → long‑mode, kernel load at 0x100000 |
| **Kernel entry** | `xk_main.c3` | BSS zeroing → `xk_boot()` |
| **Boot/core** | `xk_core.c3` | Boot sequencing, serial, framebuffer, memory init, AI config, PCI, network, shell, apps, idle loop |
| **Interrupts** | `xk_intr.c3` | IDT (48 stubs + INT 0x80), PIC remap, PIT 100 Hz, exception dump, IRQ dispatch |
| **Scheduler** | `xk_sched.c3` | Cooperative round‑robin + timer preemption (100 Hz), 8 tasks, 16 KiB stacks |
| **Memory** | `xk_mem.c3`, `xk_alloc.c3` | `memset/memcpy/memmove/memcmp` exports; frame allocator + first‑fit heap |
| **PCI/AHCI** | `xk_pci.c3`, `xk_ahci.c3` | PCI enumeration, bus‑master enable, AHCI reset/link/command |
| **ATA** | `xk_ata.c3` | IDE/ATA PIO (primary/secondary channels) |
| **FAT16** | `xk_fat.c3` | Mount, directory traversal, cluster‑chain reads |
| **ext4** | `xk_ext4.c3` | Read‑only: superblock, group desc, inode, extent tree (depth‑0/1), file data |
| **Linux ELF** | `xk_linux.c3` | ELF64 loader, virtual memory layout, POSIX syscalls, ring‑3 process table, fork/exec |
| **Syscalls** | `xk_sys.c3` | `int 0x80` dispatch: PUTS, GETPID, TICKS, UMSG, EXIT, RESULT |
| **Ring‑3 setup** | `xk_umode.c3` | TSS, user mappings, transition to ring‑3 |
| **Framebuffer** | `xk_fb.c3` | Shadow buffer, pixel/rect/text, dirty‑rect blit to VRAM |
| **Font** | `xk_font.c3` | 8×8 bitmap font (generated by `tools/mkfont.py`, committed) |
| **Window manager** | `xk_wm.c3` | Titles, focus, drag, close, dock, z‑order, per‑window damage |
| **Apps** | `xk_apps.c3` | Terminal (shell host), clock, animated demo |
| **Shell** | `xk_shell.c3` | Command interpreter + tiny VFS catalog |
| **Keyboard** | `xk_kbd.c3` | PS/2 scancode set 1 → ASCII, shift |
| **Mouse** | `xk_mouse.c3` | PS/2 auxiliary, three‑byte packets |
| **Wayland** | `xk_wl.c3` | Kernel Wayland compositor protocol, Unix‑socket‑facing |
| **Network** | `xk_net.c3` | e1000 NIC, Ethernet |
| **IP/TCP/HTTP** | `xk_ip.c3`, `xk_tcp.c3`, `xk_http.c3` | IPv4, TCP stream, HTTP client |
| **TLS/crypto** | `xk_tls.c3`, `xk_sha256.c3`, `xk_aes.c3` | TLS 1.2 handshake, SHA‑256, AES‑GCM |
| **AI path** | `xk_ai_cfg.c3`, `xk_ai_client.c3`, `xk_chat.c3`, `xk_agent.c3` | AI endpoint/config, remote client, chat, agent orchestration |

### Data/Control Flows

1. **Boot**: BIOS → stage1 (0x7c00) → stage2 (0x8000) → kernel (0x100000) → `xk_main` → `xk_boot`.
2. **Desktop idle loop** (`xk_idle_loop` in `xk_core.c3`): `thread_yield` → `xk_hlt` → keyboard drain → `wm_tick` → `net_poll` → app clock/demo updates → `fb_cursor`.
3. **Framebuffer**: apps draw into shadow buffer at (x, y+TITLE_H); `wm_composite` repaints background + dock + all windows; `wm_present_all` blits dirty rects to VRAM.
4. **Input**: PS/2 IRQ1 (keyboard) / IRQ12 (mouse) → ISR → `kbd_has/pop` or `mouse_*` globals → `wm_key`/`wm_tick`.
5. **Wayland**: libwayland‑client on host ↔ kernel compositor on `/run/wayland-0` via Unix socket → `wl_emit*` functions build wire frames.
6. **Network**: e1000 IRQ → `net_poll` → ARP/TCP stack → HTTP client → AI provider (or mock).
7. **Userspace**: ring‑3 program ↔ kernel via `int 0x80` (SYS_UMSG, SYS_EXIT, SYS_RESULT) or `syscall` instruction for Linux ELF processes.

### Dependencies Between Subsystems

- **Boot depends on**: ATA PIO (stage2 loads kernel), VBE (bootloader negotiates framebuffer).
- **Kernel core depends on**: all low‑level drivers (PCI, AHCI, net, fb, font, kbd, mouse), allocator, scheduler.
- **Window manager depends on**: framebuffer (shadow + VRAM blit), keyboard/mouse state, apps registry.
- **Apps depend on**: framebuffer, keyboard input, shell VFS, clock ticks.
- **Wayland compositor depends on**: socket FD infrastructure, SHM pool, framebuffer.
- **Linux ELF loader depends on**: PCI/AHCI (for rootfs), FAT/ext4 (for file‑backed .so), mmap, fork.
- **Networking depends on**: e1000 NIC, PCI (bus‑master enable is critical for DMA).
- **AI modules depend on**: network (HTTP/TLS), AI config (from FAT).

## C3 for xenOS

### C3 Concepts Used Frequently

- **Modules** (`module xk;`): Every kernel source file is a C3 module named `xk`. All kernel symbols live in a single global namespace per module; cross‑module access uses `extern fn` declarations.
- **`@export("name")`**: Exports a symbol under a specific linker name. Critical for `xk_main` (`@export("xk_main")`), `xk_handle_isr`, and the memory helpers (`memset`, `memcpy`, `memmove`, `memcmp`).
- **`extern fn`**: Declares a function defined elsewhere (typically in `asm_runtime.asm` or another C3 module). Used for all assembly‑level routines: `xk_switch`, `xk_preempt_resume`, `xk_get_ticks`, `xk_inb`/`xk_outb`, `xk_lgdt`, `xk_lidt`, etc.
- **`alias`**: C3's type alias — needed for function‑pointer types. Example: `alias TaskFn = fn void();`, `alias IrqHandler = fn void(IntFrame*);`. Without an alias, C3 doesn't allow direct function‑pointer variable declarations with parameters.
- **`&fn`**: Address‑of‑function syntax. Used when passing function pointers: `thread_create(&demo_task_a, "demo-a")`.
- **Arrays**: `T[n] x` — fixed‑size arrays, no decay to pointers. Pass `&x[0]` to get a pointer. Example: `char[1024] g_e4_blk;` in `xk_ext4.c3`.
- **Lowercase mutable globals**: `g_tasks`, `g_current`, `g_fb_w` — all mutable module globals must be lowercase. Uppercase = comptime const/type.
- **Braced `if/else`**: Every `if`/`else` body must be braced, even for single statements.
- **No implicit `main`**: Freestanding entry is `xk_main` (linked first, `@export`).
- **`--target elf-x64 --no-entry --use-stdlib=no --x86cpu=baseline --x86vec=none`**: The freestanding C3 compilation flags. `--x86cpu=baseline --x86vec=none` prevents SSE/AVX instructions that `#UD` on QEMU's default CPU.
- **`c3c compile-only`**: Parses C3 → JSON AST (signatures only, no bodies). Used by agent‑map and for compile‑time verification without generating code.

### Project‑Specific Patterns

- **Module‑based ownership**: Each `xk_*.c3` owns a subsystem. New subsystems get their own `xk_*.c3` file.
- **Global state tables**: `g_tasks[MAX_TASKS]`, `g_sock[MAX_SOCKETS]`, `g_fd[MAX_FDS]`, `g_wl[4]`, `g_epolls[8]` — fixed‑capacity arrays, not dynamic allocations.
- **Interrupt‑saving state**: `Task.saved_frame` (real ISR frame), `g_tasks[cur].saved_frame` — only real interrupt frames are iretq'd; no hand‑crafted frames.
- **FD‑typed kernel**: `LxFD` struct carries `type` (FD_NONE/FD_FILE/FD_SOCK/FD_EPOLL/FD_NULL/FD_ZERO/FD_SHM/FD_EVENT); callers must preserve kind.
- **BootInfo handoff**: Physical 0x7000, passed from stage1 → stage2 → kernel; contains framebuffer addr/geometry and drive info.

### Non‑obvious C3 Syntax/Patterns

- **Function‑pointer params need a named alias**: `alias H = fn void(X); H f;` — then `f = &fn_name`. Direct `fn void(X) f;` is a syntax error.
- **Arrays don't decay**: `char[1024] buf;` — to pass to a function expecting `char*`, use `&buf[0]`.
- **Lowercase mutable globals**: `g_up[]` (not `G_UP[]`). All‑caps is for comptime constants/types.
- **Braced single‑statement bodies**: `if (x) { y; }` — no unbraced single statements.
- **`for` loop with variable declarations**: `for (int i = 0; i < n; i++)` — C3 allows `int` declarations in `for` init.
- **`while (true) { xk_hlt(); }`**: The idle loop pattern; `xk_hlt()` is an external asm call that halts the CPU until the next interrupt.
- **`xk_get_ticks()`**: Must be called through the asm extern, NOT by reading `g_ticks` directly — the C3 compiler would hoist the read out of a busy loop as a loop invariant.

### Memory/Ownership Model

- **No libc allocator**: `kmalloc`/`kfree` use a first‑fit heap (2 MiB reserved at 0x01000000). No `malloc`/`free` from any C library.
- **Frame allocator**: Bitmap over physical frames 0x00100000–0x06000000 (96 frames of 4 KiB). `frame_alloc`/`frame_free`/`frame_mark_range`.
- **Per‑task stacks**: 16 KiB each, fixed at `STACKS_BASE = 0x3000000`. Task index determines stack location.
- **Shadow framebuffer**: 1920×1080×4 bytes ≈ 8.3 MiB at 0x02000000 (statically reserved).
- **No dynamic allocation in IRQ context**: `irq_timer` calls `sched_timer` which calls `xk_switch` — no allocations there.
- **FD table**: `LxFD[MAX_FDS]` — 32 slots, pre‑allocated, no growth.

## Build/Tooling

### Build Commands

```sh
./build.sh                  # Full build: boot stages, kernel, rootfs, image, ISO
./run.sh                    # Boot graphical desktop (QEMU, VGA)
./run.sh serial             # Headless boot (serial console in terminal)
./run.sh serial             # Headless boot with serial console in terminal
qemu-system-x86_64 -cdrom build/xenos.iso -m 256 -boot d   # ISO boot
qemu-system-x86_64 -drive file=build/xenos.img,format=raw -m 256  # Disk boot
```

### Toolchain

- **c3c** 0.8.x (Arch: `sudo pacman -S c3c`) — C3 compiler, LLVM‑based.
- **nasm** — assembler for boot stages, host runtime, asm runtime.
- **ld/objcopy** — GNU ld for linking (elf_x86_64), objcopy for binary extraction.
- **python3** — only for `mkfont.py` (font generation) and host test scripts; NOT used by the main build.
- **qemu-system-x86_64** — TCG (no KVM on this host; guest runs under TCG, slow).
- **xorrisofs** — optional; enables ISO output.
- **musl‑gcc** — optional; for cross‑building userspace tests and the dynamic GTK app.
- **mke2fs** — for ext4 rootfs creation (build.sh calls it).

### Generated Files (in `build/`)

| File | Origin | Description |
|------|--------|-------------|
| `stage1.bin` | `boot/stage1.asm` | 512‑byte real‑mode boot sector |
| `stage2.bin` | `boot/stage2.asm` | Long‑mode trampoline |
| `kernel.bin` | C3 compile + ld + objcopy | Freestanding kernel at 0x100000 |
| `xenos.img` | `mkdisk` | Raw bootable disk image |
| `xenos.iso` | `mkbootimg` + `xorrisofs` | El Torito bootable ISO |
| `fat.img` / `sata.img` | `mkfat` | FAT16 data volume (8 MiB) with AI token + INTERP |
| `rootfs.ext4` | `mke2fs` | ext4 rootfs (64 MiB, read‑only, no journal) |
| `user_prog.bin` | `sys_prog.asm` + `mkbin` | Embedded ring‑3 program |
| `xk_uprog.c3` / `xk_ublob.c3` / `xk_dynblob.c3` | `mkbin` | Generated C3 embedded arrays (do NOT edit directly) |
| `host_start.o` | `tools/host_start.asm` | Freestanding host runtime for C3 tools |
| `ccobl/obj/elf-x64/*.o` | C3 compile‑only | Kernel object files (intermediate) |

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/boot_verify.sh` | Headless boot + serial assertions + desktop screenshot |
| `scripts/test.sh` | Host‑side unit tests (SHA‑256, AES‑GCM, P‑256, ext4read) |
| `scripts/ai_selftest.sh` | Headless boot + capture ARP/TCP/HTTP lines |
| `scripts/ai_connectivity_test.sh` | Boot → type `aichat hello` → check mock received |
| `scripts/mouse_alive_test.sh` | VNC screenshots t0/t18 + mouse move → screenshot t19 |
| `scripts/crossbuild_deps.sh` | Cross‑build static musl deps (libffi, wayland, etc.) |
| `scripts/crossbuild_shared.sh` | Cross‑build shared musl .so tree (Phase E3) |
| `scripts/crossbuild_xwayland.sh` | Cross‑build Xwayland + X11 deps |
| `scripts/crossbuild_xfce.sh` | Cross‑build Xfce 4.18 |
| `scripts/stage_xfce_rootfs.sh` | Stage Xfce binaries, SONAME links, XKB/DBus, data |

### Bootstrap/Build Pipeline

1. `build.sh` assembles `stage1.bin`/`stage2.bin` with nasm.
2. Builds host tools (`mkdisk`, `mkbin`, `mkbootimg`, `mkfat`, `ext4read`) — freestanding C3 + `host_start.asm`.
3. Stages rootfs: creates `rootfs/` directory, copies dynamic main + shared libs, builds ext4 image.
4. Builds kernel: `c3c compile-only` on all `kernel/src/*.c3`, then `ld -m elf_x86_64 -T kernel/linker.ld` (entry object first so `xk_main` lands at 0x100000), then `objcopy -O binary`.
5. `mkdisk` assembles the raw disk image (stage1 + stage2 + kernel.bin → `xenos.img`).
6. `mkbootimg` + `xorrisofs` (if available) → `xenos.iso`.
7. `mkfat` builds FAT16 volume with AI token and INTERP path.
8. `cp fat.img sata.img` — identical volume shown to AHCI controller.

## Refactor History

### Phases (from git history)

| Phase | Milestone | Key Changes |
|-------|-----------|-------------|
| **Phase A** | Ring‑3 + processes | Distinct per‑process address space (own CR3), TSS, ring‑3 demo program, `int 0x80` syscall gate (DPL=3), cooperative scheduler, first fork (synchronous child‑first). |
| **Phase B** | POSIX layer | `stat`/`fstat`/`newfstatat`, `clone`/`clone3`/`fsync`/`membarrier`, `epoll_create1`/`ctl`/`wait`, `poll`/`ppoll`, AF_UNIX named server sockets + socketpair, `MAP_SHARED` anonymous mmap, `/dev/shm` + `wl_shm` pool, `ioctl` dispatch, `/dev/null` + `/dev/zero`. |
| **Phase C** | ext4 rootfs | Read‑only ext4 driver (superblock, group desc, inode, extent tree depth‑0/1), host‑side validation (`tools/ext4read.c3`), wired into Linux file layer. |
| **Phase D** | Wayland compositor | Real Wayland wire protocol on `/run/wayland-0`, `wl_display.get_registry`, `wl_compositor` + `wl_shm` globals, `wl_surface.frame` callbacks, multi‑window + tiled presentation, keyboard/mouse input events, `wl_shell`/`xdg_wm_base` for GDK toplevel, `wl_shm` pool present infra. |
| **Phase E** | Userspace toolchain | Cross‑build static musl deps (libffi, wayland, pixman, xkbcommon, glib, pango, harfbuzz, cairo, gdk‑pixbuf, atk, GTK3), GTK3 core libs built static‑musl, fontconfig + freetype shared, zlib. |
| **Phase E2** | GTK3 core | Static‑musl GTK3 core libraries (libgtk‑3.a = 52 MB, libgdk‑3.a), shared GTK3 rebuild (`.so` tree), dynamic main (`dynmain`) linked against shared libs. |
| **Phase E3** | Dynamic loader | musl libc.so staged as dynamic loader on rootfs, full shared .so loader, dynamic GTK app RUNS in‑guest. |
| **Phase F** | Desktop | XWayland cross‑build, Xfce 4.18 cross‑build, runtime staging (binaries + SONAME links + XKB/DBus + GTK data). |
| **Post‑F** | AI + networking | e1000 + ARP/IPv4/TCP/HTTP from scratch, TLS 1.2 (SHA‑256, HMAC, AES‑GCM, ECDHE‑RSA, P‑256), AI chat/agent modules, mock AI provider, network‑driven AI transport. |

### Key Architectural Changes (Why They Happened)

1. **Freestanding kernel** (no libc) — deliberate design choice: tight control over syscall ABI, no hidden dependencies, full control over memory layout.
2. **Cooperative scheduling** — chosen because QEMU 11's `iretq` rejects hand‑crafted interrupt frames; a hybrid `xk_switch` + real‑frame‑`iretq` pair works reliably.
3. **Per‑process CR3** — each task gets its own page tables (identity 0..4GiB, only its own 2 MiB page U/S); kernel stays isolated, shared kernel tables never made user‑accessible.
4. **FD‑typed kernel** — simplifies type safety; every descriptor carries its kind; matching subsystem operations must be used.
5. **Shared GTK .so tree (Phase E3)** — the static‑archive tree (100 MB ELF) cannot host a GTK app via kernel rootfs‑exec (whole image must fit one kernel heap buffer); dynamic `.so` main is tiny; kernel maps interpreter + DT_NEEDED chain from ext4 rootfs.
6. **PCI bus‑master enable** — discovered that QEMU's PCI DMA silently no‑ops without Bus‑Master bit (Command reg 0x04); this was the real root cause of "e1000/AHCI DMA broken" failures, NOT a QEMU bug.
7. **Agent‑map as soft requirement** — `c3c -P compile-only` gives real parsed C3 AST as JSON (signatures only); useful for symbol/dependency navigation in `xk_wl.c3`, `xk_linux.c3`, `xk_ext4.c3`.

### Old vs Current Architecture

- **Old**: Hardcoded catalog in shell → replaced by real FAT16 filesystem (Phase D? — actually earlier).
- **Old**: Single static‑archive GTK → replaced by shared `.so` tree (Phase E3).
- **Old**: No real Wayland → `wl_display` + registry + globals + SHM + frame callbacks (Phase D).
- **Old**: No ext4 → real ext4 read‑only driver with extent trees (Phase C).
- **Old**: No POSIX syscalls → full Linux syscall ABI with `syscall` instruction (Phase B).
- **Old**: No ring‑3 isolation → per‑process CR3 + TSS + `iretq` to ring‑3 (Phase A).
- **Current**: All the above, plus AI/agent modules (stub), Xfce staging, TLS crypto from scratch.

### Refactor Status

- **Phase A–F**: All committed and boot‑verified individually.
- **AHCI DMA**: Still the unresolved piece (Phase F/D hardware).
- **AI modules**: Skeleton only, not integrated.
- **Xfce runtime**: Staged but not fully interactive‑tested.

## Important Files/Symbols (~30)

| File/Symbol | Type | Why It Matters |
|-------------|------|----------------|
| `kernel/src/xk_main.c3` | C3 module | Kernel entry point (linked at 0x100000); zeros BSS → `xk_boot()` |
| `kernel/src/xk_core.c3` | C3 module | Boot sequence, framebuffer init, memory init, AI config, PCI, network idle loop |
| `kernel/src/xk_sched.c3` | C3 module | Cooperative round‑robin scheduler, timer preemption, task creation/yield |
| `kernel/src/xk_intr.c3` | C3 module | IDT (48 vectors + INT 0x80), PIC, PIT, IRQ dispatch, exception handling |
| `kernel/src/xk_sys.c3` | C3 module | `int 0x80` syscall dispatch (SYS_PUTS/GETPID/TICKS/UMSG/EXIT/RESULT) |
| `kernel/src/xk_linux.c3` | C3 module (2077 lines) | Linux ELF loader, POSIX syscalls, ring‑3 process table, fork/exec, mmap |
| `kernel/src/xk_wl.c3` | C3 module (416 lines) | Wayland compositor protocol, wire‑frame emission, SHM pool |
| `kernel/src/xk_fb.c3` | C3 module | Shadow framebuffer, pixel/rect/text, dirty‑rect blit to VRAM |
| `kernel/src/xk_wm.c3` | C3 module | Window manager: titles, focus, drag, close, dock, z‑order |
| `kernel/src/xk_apps.c3` | C3 module | Terminal (shell host), clock, animated demo |
| `kernel/src/xk_pci.c3` | C3 module | PCI enumeration, AHCI detection, bus‑master enable (critical for DMA) |
| `kernel/src/xk_ahci.c3` | C3 module | SATA AHCI controller/link setup, command issue (DMA path broken) |
| `kernel/src/xk_ata.c3` | C3 module | IDE/ATA PIO disk access (primary + secondary channels) |
| `kernel/src/xk_fat.c3` | C3 module | FAT16 mount, directory traversal, cluster‑chain reads |
| `kernel/src/xk_ext4.c3` | C3 module (319 lines) | Read‑only ext4: superblock, group desc, inode, extent tree (depth‑0/1) |
| `kernel/src/xk_mem.c3` | C3 module | `memset/memcpy/memmove/memcmp` exported under linker names |
| `kernel/src/xk_alloc.c3` | C3 module | Physical frame allocator + first‑fit kernel heap |
| `kernel/src/xk_net.c3` | C3 module | e1000 NIC, Ethernet frame handling |
| `kernel/src/xk_ip.c3` | C3 module | IPv4 packet construction/parsing |
| `kernel/src/xk_tcp.c3` | C3 module | TCP connection/stream state |
| `kernel/src/xk_http.c3` | C3 module | HTTP request/response handling |
| `kernel/src/xk_tls.c3` | C3 module | TLS 1.2 handshake, record path |
| `kernel/src/xk_sha256.c3` | C3 module | SHA‑256 primitives (FIPS 180‑4) |
| `kernel/src/xk_aes.c3` | C3 module | AES‑128 + AES‑GCM (NIST SP 800‑38D) |
| `kernel/src/xk_ai_cfg.c3` | C3 module | AI endpoint/configuration handling (reads AI.CFG from FAT) |
| `kernel/src/xk_ai_client.c3` | C3 module | Remote AI request client (HTTP/TLS) |
| `kernel/src/xk_chat.c3` | C3 module | Chat request/response presentation |
| `kernel/src/xk_agent.c3` | C3 module | Agent orchestration on top of chat/client |
| `kernel/src/xk_shell.c3` | C3 module | Interactive shell + tiny VFS catalog |
| `kernel/src/asm_runtime.asm` | ASM | Port I/O, interrupt stubs, context switch (`xk_switch`), `iretq` |
| `kernel/linker.ld` | Linker script | Flat 1 MiB layout; xk_main first so entry == 0x100000 |
| `boot/stage1.asm` | ASM | 512‑byte real‑mode boot sector (VBE, loads stage2) |
| `boot/stage2.asm` | ASM | Long‑mode trampoline: GDT, page tables, ATA PIO kernel load |
| `tools/mkfat.c3` | C3 host tool | Creates FAT16 data volume, stages files |
| `tools/mkbin.c3` | C3 host tool | Converts binary → embedded C3 arrays (`xk_uprog.c3`, `xk_ublob.c3`, `xk_dynblob.c3`) |
| `tools/mkfont.py` | Python | Generates `xk_font.c3` 8×8 bitmap font (dev‑time only; font is committed) |
| `tools/host_start.asm` | ASM | Freestanding host runtime (_start + Linux syscalls) for C3 tools |
| `scripts/boot_verify.sh` | Bash | Headless boot + serial assertions + desktop screenshot |
| `scripts/test.sh` | Bash | Host‑side unit tests (SHA‑256, AES‑GCM, P‑256, ext4read) |
| `AGENTS.md` | Markdown | This file — durable handoff for the next AI agent |

## Invariants

### Memory/Lifetime
1. **No libc allocator** — `kmalloc`/`kfree` only; no `malloc`/`free` from any C library.
2. **Fixed global tables** — `g_tasks[MAX_TASKS]`, `g_sock[]`, `g_fd[MAX_FDS]`, `g_wl[4]`, `g_epolls[8]` — pre‑allocated, fixed capacity, no growth.
3. **Per‑task stacks** — 16 KiB each at `STACKS_BASE = 0x3000000`; task index determines stack location; stack locals do NOT reliably survive preemption (use module globals for long‑lived state).
4. **Shadow framebuffer** — 1920×1080×4 bytes at 0x02000000; statically reserved; dirty‑rect blits only.
5. **Heap** — 2 MiB at 0x01000000; first‑fit with splitting + next‑coalescing; no defragmentation.

### API/ABI
1. **Syscall ABI** — `int 0x80` (vector 128) for ring‑3; `SYS_PUTS`/`GETPID`/`TICKS`/`UMSG`/`EXIT`/`RESULT`; registers: rax=n, rbx=arg1, rcx=arg2, rdx=arg3; result in rax.
2. **Linux syscall ABI** — `syscall` instruction with MSR LSTAR → `syscall_entry` in `asm_runtime.asm` → `xk_linux_syscall`; preserves rdi/rsi/rdx/r10/r8/r9 across `syscall` (musl caches &st in r8 — handler must restore all 8 saved regs).
3. **FD‑typed kernel** — every FD carries its type (`FD_NONE/FD_FILE/FD_SOCK/FD_EPOLL/FD_NULL/FD_ZERO/FD_SHM/FD_EVENT`); callers must preserve kind and use matching subsystem operations.
4. **PCI config space** — `0xCF8`/`0xCFC` address/data ports; `pci_enable_bus_master()` must be called for any DMA device.

### Concurrency
1. **Cooperative scheduling** — preemption via PIT timer (100 Hz); tasks voluntarily yield or are preempted at defined scheduler points.
2. **No preemption safety** — arbitrary kernel code is NOT preemption‑safe; long‑lived per‑task state lives in module globals, not stack locals.
3. **Timer ISR** — `irq_timer` → `sched_timer` → `xk_switch` + `xk_preempt_resume` (real‑frame `iretq`); only real ISR frames are iretq'd.
4. **IRQ masking during ring‑3** — `xk_mask_hw_irqs(on)` masks all 8259 IRQs while a Linux ring‑3 process runs (QEMU's `iretq` is fragile mid‑iretq).

### Layout/Ordering
1. **Kernel entry** — `xk_main` MUST be the first function in its object, linked first, so `call 0x100000` lands on it.
2. **Physical memory map** — stage1 @0x7c00, BootInfo @0x7000, stage2 @0x8000, page tables/GDT @0x9000–0xF000, kernel stack @0x90000, kernel @0x100000, shadow fb @0x02000000, task stacks @0x3000000, VESA LFB @0xFD000000.
3. **User address space** — `LX_USER_START=0x00400000` (static non‑PIE), `LX_HEAP_END=0x00A00000`, `LX_STACK_TOP=0x0FF00000`, `LX_INTERP_BASE=0x0A000000` (ld‑musl), `LX_MMAP_BASE=0x0C000000`.
4. **ext4** — 1024‑byte blocks, EXTENTS‑only (magic 0xF30A, depth‑0 leaves), filetype directory entries, inline symlinks ≤60 bytes.
5. **FAT16** — 512‑byte sectors, 1 sector/cluster, 1 reserved sector, 1 FAT of 64 sectors, 512 root entries.

### Runtime
1. **Boot‑verified milestones** — every major phase is boot‑tested under QEMU TCG before being considered complete.
2. **No SSE/AVX** — `--x86cpu=baseline --x86vec=none` prevents SSE/AVX instructions that `#UD` on QEMU's default CPU; `xk_enable_sse()` enables CR4.OSFXSR/OSXMMEXCPT for ring‑3 Linux binaries.
3. **QEMU iretq fragility** — hand‑crafted interrupt frames are rejected by QEMU 11's `iretq`; only real `isr_common` frames are `iretq`'d.
4. **C3 compile‑only** — `c3c compile-only --target elf-x64 --no-entry --use-stdlib=no --x86cpu=baseline --x86vec=none` is the freestanding compilation mode.

## Current State

### Stable (Verified Boot)
- Boot chain (BIOS → stage1 → stage2 → kernel → desktop) under QEMU TCG.
- Kernel core: scheduler, memory, interrupts, PCI/AHCI, FAT16, ext4, framebuffer, font, WM, apps, shell.
- Userspace: Linux ELF loader (static + dynamic), AF_UNIX, epoll, eventfd, /dev/shm, MAP_SHARED, ioctl, fork (sync), file‑backed mmap.
- Dynamic GTK app runs in‑guest against shared musl .so tree on ext4 rootfs.
- Wayland compositor (kernel side) with stock libwayland‑client rendering to framebuffer.
- Networking: e1000 + ARP + IPv4 + TCP + HTTP + TLS 1.2 (self‑tests pass).
- Xfce 4.18 + XWayland cross‑built and staged.

### Temporary / Workarounds
- Serial console fallback when FAT16 not mounted.
- Placeholder blobs when musl‑gcc missing (`xk_ublob.c3`/`xk_dynblob.c3` emptied).
- `g_last_sec_*` module globals for demo task timing (stack locals don't survive preemption).

### Experimental / Incomplete
- AI/agent modules (`xk_ai_cfg.c3`, `xk_ai_client.c3`, `xk_chat.c3`, `xk_agent.c3`) — skeleton/stub, no real remote AI.
- AHCI DMA data path — link up but no data lands in guest buffers.
- Multi‑process ring‑3 — one process at a time; no fork/exec table.
- Xfce runtime — staged but not fully interactive‑tested end‑to‑end.

### Technical Debt
- **AHCI DMA** — the primary unresolved hardware issue.
- **Single‑process ring‑3** — fork/exec needed for a real desktop.
- **Build fragility** — optional tools (`xorrisofs`, `musl-gcc`) cause placeholder/reduced artifacts; no fast‑fail on missing deps.
- **Generated blobs** — `xk_uprog.c3`, `xk_ublob.c3`, `xk_dynblob.c3` are generated; editing them directly is discouraged (regenerate via `build.sh` or `mkbin`).
- **AI modules** — stubs; need real backend integration.

## Unknowns/Problems

| Area | Issue | Confidence | Notes |
|------|-------|------------|-------|
| AHCI DMA | Data DMA path returns zeroed buffers | **Confirmed** — observed in QEMU; PRD descriptors correct but no data lands | Known since early AHCI work; PCI bus‑master enable fixes QEMU DMA no‑op but data still doesn't arrive |
| Ring‑3 preemption | QEMU 11's `iretq` rejects hand‑crafted frames | **Confirmed** — `irq_timer` saves real frame, `xk_preempt_resume` iretq's it | Workaround: hybrid `xk_switch` + real‑frame‑`iretq`; no concurrent preemption of ring‑3 |
| IRQ tearing | PIT ISR can capture a ring‑3 → ring‑0 → ring‑3 transition mid‑iretq | **Confirmed** — `sched_timer` checks `f.cs == 0x18` (kernel CS) before saving frame | Torn selectors (0x28) cause #GP on resume |
| AI modules | Stub/mock implementations | **Confirmed** — `ai_mock.c3`/`ai_mock_py.py` provide local test server | Real AI integration (OpenAI/Anthropic) not done |
| Xfce runtime | Staged but not interactive‑tested | **Hypothesis** — desktop boots (screenshot verified), but full Xfce session not proven | Run `scripts/stage_xfce_rootfs.sh` + verify interactive desktop |
| ext4 write | Read‑only; no journal/metadata checksums | **Confirmed** — `mke2fs` disables journal/metadata_csum/64bit etc. | Write support would require journal + checksum + bitmap updates |
| Memory fragmentation | First‑fit heap, no defrag | **Hypothesis** — small heap (2 MiB), fragmentation unlikely but possible under sustained allocation/deallocation | Monitor `heap_bytes_in_use` |
| Network throughput | e1000 + TCG slowness | **Hypothesis** — not benchmarked; TCG is slow | Not a blocker for AI mock (small HTTP requests) |

## Development Guidance

### How to Safely Modify xenOS

1. **Always boot‑verify** — after any kernel change, run `./build.sh` then `./run.sh` (or `./scripts/boot_verify.sh` for headless). A compile‑only success is NOT boot evidence.
2. **Use agent‑map for kernel exploration** — `c3c -P compile-only kernel/src/*.c3` → JSON AST with signatures; useful for mapping symbol/dependency interconnections before touching code. This is a SOFT requirement: use it for kernel symbol/dependency navigation, refactors, adding new `xk_*.c3` modules, tracing interdependencies. Not needed for quick greps or userspace work.
3. **Respect the C3 conventions** — lowercase mutable globals, braced `if/else`, `alias` for function‑pointer types, `&fn` for function addresses, arrays pass `&x[0]`, no SSE/AVX (`--x86cpu=baseline --x86vec=none`).
4. **No hand‑crafted iretq frames** — QEMU 11 rejects them. Only real `isr_common` frames are `iretq`'d. Task entry uses `xk_switch` (cooperative callee‑saved frame; `ret` lands on entry).
5. **PCI bus‑master** — always call `pci_enable_bus_master()` for any DMA device (e1000, AHCI). Without it, QEMU's PCI DMA silently no‑ops.
6. **IRQ masking** — mask all 8259 IRQs while a Linux ring‑3 process runs (`xk_mask_hw_irqs(1)`); re‑enable on exit. Prevents torn ISR frames during ring‑0/3 transitions.
7. **Generated blobs** — don't edit `xk_uprog.c3`, `xk_ublob.c3`, `xk_dynblob.c3` directly; regenerate via `mkbin` or `build.sh`.
8. **Cross‑build dependencies** — `scripts/crossbuild_deps.sh` builds the static musl sysroot; `scripts/crossbuild_shared.sh` rebuilds as shared `.so` for the dynamic loader. Both require `musl-gcc`, `meson`, `ninja`, `autotools`, `pkg-config`.
9. **Test incrementally** — run the smallest relevant self‑test (`scripts/test.sh` for crypto/ext4, `scripts/ai_selftest.sh` for networking, `scripts/boot_verify.sh` for full boot) before declaring a change complete.
10. **Commit milestones** — every milestone is boot‑verified and committed. Do not claim completion without real boot/output evidence.

### What to Avoid

- **Don't add SSE/AVX assumptions** — QEMU's default CPU doesn't support them; `--x86cpu=baseline --x86vec=none` prevents emission, but `xk_enable_sse()` must be called for ring‑3 Linux binaries.
- **Don't iretq a hand‑crafted frame** — QEMU 11 #GP's on it. Use `xk_switch` + real‑frame‑`iretq` only.
- **Don't make the kernel non‑freestanding** — no libc, no glibc; all syscalls through `int 0x80`.
- **Don't add dynamic kernel allocations** — the heap is 2 MiB first‑fit; kernel subsystems should use static/global tables.
- **Don't edit generated C3 blobs** — `xk_uprog.c3`, `xk_ublob.c3`, `xk_dynblob.c3` are produced by `mkbin`; edit the source binary or the generator instead.
- **Don't skip IRQ masking during ring‑3** — without it, PIT/keyboard/mouse IRQs can land mid‑`iretq` and tear the frame.
- **Don't claim AHCI is fixed** — the DMA data path is still broken; only the controller init/link/command path works.

### What to Test

- **Boot verification** — `./scripts/boot_verify.sh` (headless boot + serial assertions + screenshot).
- **Unit tests** — `./scripts/test.sh` (SHA‑256, AES‑GCM, P‑256, ext4read known‑answer vectors).
- **Network** — `./scripts/ai_connectivity_test.sh` (boot → `aichat hello` → mock received).
- **Mouse** — `./scripts/mouse_alive_test.sh` (VNC screenshots, cursor alive, RFB move).
- **Self‑test** — `./scripts/ai_selftest.sh` (headless boot, capture ARP/TCP/HTTP lines).

## Agent Memory (Non‑obvious Knowledge)

### Why Decisions Were Made

1. **Freestanding kernel (no libc)** — deliberate: tight control over syscall ABI, no hidden dependencies, full control over memory layout. The cost is reimplementing `memset`/`memcpy` etc. in C3.
2. **Cooperative scheduling** — QEMU 11's `iretq` rejects hand‑crafted interrupt frames; a hybrid `xk_switch` + real‑frame‑`iretq` pair is the only approach that works. Preemption is timer‑driven but tasks are switched at defined points, not arbitrarily inside kernel code.
3. **Per‑process CR3** — each task gets its own page tables (identity 0..4GiB, only its own 2 MiB page U/S); kernel stays isolated, shared kernel tables never made user‑accessible. This enables distinct‑CR3 processes but complicates shared data (handled via global tables).
4. **FD‑typed kernel** — simplifies type safety; every descriptor carries its kind; matching subsystem operations must be used. Prevents fd‑type confusion bugs.
5. **Shared GTK .so tree (Phase E3)** — the static‑archive tree (100 MB ELF) cannot host a GTK app via kernel rootfs‑exec (whole image must fit one kernel heap buffer); dynamic `.so` main is tiny; kernel maps interpreter + DT_NEEDED chain from ext4 rootfs. This was a hard‑won pivot from static to shared.
6. **PCI bus‑master enable** — discovered that QEMU's PCI DMA silently no‑ops without Bus‑Master bit (Command reg 0x04); this was the real root cause of "e1000/AHCI DMA broken" failures, NOT a QEMU bug. `pci_enable_bus_master()` is the fix.
7. **Agent‑map as soft requirement** — `c3c -P compile-only` gives real parsed C3 AST as JSON (signatures only, no bodies); useful for symbol/dependency navigation in `xk_wl.c3`, `xk_linux.c3`, `xk_ext4.c3`. The `agent-map` skill (repo `xenOS-AI/agent-map`) provides this.
8. **`xk_get_ticks()` through asm extern** — reading `g_ticks` directly lets the C3 compiler hoist `g_ticks/100` out of a busy loop as a loop invariant, so per‑second prints never fire. The asm call prevents this optimization.
9. **`cur_bg` snapshot for cursor** — mouse cursor drawn directly into VRAM (not compositor shadow) so it stays on top; background is snapshotted and restored before each redraw to avoid trails. The 12×16 background array (`cur_bg[192]`) is saved per‑cursor‑position.
10. **`wl_emit_keyboard_keymap` placeholder** — the keymap event has no actual keymap data; it's a placeholder that satisfies GDK seat build. Real keymap data (XKB) is not wired yet.

### Failed Approaches / Abandoned Paths

1. **Static GTK archive → dynamic .so pivot** — the static‑archive tree (100 MB ELF) couldn't fit in the kernel heap buffer for rootfs‑exec; pivoted to shared `.so` tree + dynamic loader (Phase E3). This required rebuilding all GNOME libs as shared musl `.so` files.
2. **Hand‑crafted iretq frames** — QEMU 11 rejects them with #GP; abandoned in favor of the hybrid `xk_switch` + real‑frame‑`iretq` approach. The real frame is captured by `isr_common` and saved in `Task.saved_frame`.
3. **AHCI DMA without bus‑master** — QEMU's PCI DMA silently no‑ops without Bus‑Master bit (Command reg 0x04); once bus‑master is enabled, the controller init/link/command path works but the data DMA path still doesn't land data in guest buffers. The root cause was NOT a QEMU bug — it was the missing bus‑master enable.
4. **Direct `g_ticks` read in busy loops** — C3 compiler hoists the read out of the loop as a loop invariant; the per‑second print never fires. Fixed by reading through `xk_get_ticks()` (an asm extern call).
5. **`libwayland.so.0` bytecheck** — the staged `libwayland.so.0` contains a bytecheck pattern (`\x00\x01\x02`) for validation; this is a test artifact, not production data.
6. **XKB data path** — GDK's Wayland backend makes an XKB context on the display seat; `xkb_context_new()` returns NULL with no reachable data → GTK aborts "Failed to create XKB context". Fix: mirror real XKB data into the guest at `/home/timo/crossmusl/sysroot/share/X11/xkb` (the baked default config root).

### Subtle Component Interactions

1. **`xk_idle_loop` → `wm_tick` → `fb_cursor`** — the idle loop calls `wm_tick()` which processes mouse/button events, then `fb_cursor(mouse_x, mouse_y)` draws the cursor as a VRAM overlay (erases before redraw so it never leaves trails). The cursor position is driven by accumulated mouse deltas in the ISR.
2. **`irq_timer` → `sched_timer` → `xk_switch` + `xk_preempt_resume`** — the PIT ISR increments `g_ticks`, calls `sched_timer` which saves the current task's real ISR frame, switches to the next task with `xk_switch`, and when the preempted task resumes, `xk_preempt_resume` iretq's the real frame. This is the only safe path for task resumption on QEMU 11.
3. **`net_poll` → ARP → TCP → HTTP → AI provider** — the idle loop's `net_poll()` drives the network stack; ARP resolves the host IP, TCP connects, HTTP request is sent, the mock AI provider responds. This is the full AI transport path.
4. **`wl_emit*` functions build wire frames** — the Wayland compositor emits binary wire frames to the client socket; `wl_emit_global` advertises globals (compositor, shm, seat), `wl_emit_key` sends key events, `wl_emit_ptr_motion` sends pointer motion, `wl_emit_configure` sends configure events to GDK. The wire protocol requires correct length fields (including NUL) and serial numbers.
5. **`e4_pread` sparse‑file safety** — zeros the whole window first so holes read as zeros (musl reads `.dynstr`/`.dynsym` which often sit past a hole). This is critical for shared libraries with sparse extent trees.
6. **`mkfat` AI token injection** — `build.sh` calls `mkfat` with `${XENOS_AI_TOKEN:-}`; the token is placed into the FAT image as a file; never committed. The token is read by `ai_cfg_init()` at boot from the FAT16 volume.
7. **`xk_mask_hw_irqs` during ring‑3** — while a Linux ring‑3 process runs, all device IRQs are masked so the PIT/keyboard/mouse cannot clobber a ring‑0/3 transition. IRQs are re‑enabled as soon as the process exits back to the desktop. This is needed because QEMU's `iretq` is fragile when an IRQ lands mid‑iretq.
8. **`g_shared_slot` for MAP_SHARED** — the 2 MiB user‑arena slots marked `MAP_SHARED` are tracked in `g_shared_slot[256]`; this is used by `wl_shm` pool primitive (Phase A.6) to share memory between the compositor and clients.

### Non‑Obvious C3 Patterns

1. **`alias TaskFn = fn void()`** — function‑pointer types MUST have a named alias in C3; direct `fn void() f;` is a syntax error. Assigned with `&fn_name`.
2. **`char[1024] g_e4_blk;`** — fixed‑size arrays don't decay to pointers; pass `&g_e4_blk[0]` to get a `char*`.
3. **`g_ticks` must be read via `xk_get_ticks()`** — direct read lets C3 hoist `g_ticks/100` out of a loop as a loop invariant.
4. **`if/else` bodies must be braced** — even single statements; C3 enforces this.
5. **Lowercase mutable globals** — `g_tasks`, `g_current`, `g_fb_w` — all mutable module globals must be lowercase; uppercase = comptime const/type.
6. **`for` loop with `int` declaration** — C3 allows `int i = 0` in `for` init; the scope is the loop body.
7. **`while (true) { xk_hlt(); }`** — the idle loop pattern; `xk_hlt()` halts the CPU until the next interrupt.
8. **`@export("memset")`** — exports a symbol under the exact linker name needed by freestanding code; the C3/LLVM codegen emits `memset`/`memcpy`/`memmove`/`memcmp` as linker‑name references.

---

*AGENTS.md durable handoff — generated 2026‑09‑06*
*Source: xenOS repository at /home/timo/Documents/xenOS (git HEAD: aafac3d)*
*Companion: HANDOFF.md at /home/timo/HANDOFF.md*
