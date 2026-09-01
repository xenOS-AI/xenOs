# Wayland Display Support + Xfce4 (Software → VirtIO-GPU) Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan phase-by-phase.
> This is a **multi-month program**, not a single feature. Treat each Phase as its own
> release with a green milestone (boot_verify.sh + GUI screenshot) before moving on.

**Goal:** Turn xenOS from a single-process, kernel-composited demo into a system that runs
**real Linux desktop userspace** over Wayland — a Wayland compositor, Xwayland, and an
Xfce4 session — with Xfce's windows/panel/desktop actually rendering and responding to
input under QEMU.

**Architecture:** Two-segment build. (1) Fill the Linux-kernel-shaped gap in the xenOS
kernel: multi-process userland with distinct CR3 per process, `fork`/`clone`, unix-domain
sockets + epoll/eventfd (Wayland's transport), and the minimal virtual filesystems
(`/dev/dri`, `/dev/shm`, `/dev/input`, `/run`, `/proc`) that real display servers demand.
(2) Bootstrap the real desktop userspace toolchain (mesa **software** llvmpipe/swrast →
then virtio-gpu, libwayland, a wlroots compositor, Xwayland, GTK, Xfce) as a static musl
rootfs on an ext4 volume (Phase C), and run it via the existing dynamic-musl loader
(`LIBC.SO`/`ld-musl`). Presentation stays on the QEMU stdvga framebuffer (software first)
with virtio-GPU/KMS as the follow-on optimization.

**Tech Stack:** C3 0.8.3 (kernel, freestanding) · NASM (asm runtime) · musl (static + dynamic
ELF) · libwayland · wlroots (compositor base) · sway or labwc (Xfce-on-Wayland compositor) ·
Xwayland · GTK3 (Xfce apps) · Mesa (software swrast/llvmpipe → virtio-gpu) · QEMU stdvga →
virtio-gpu · ext4 rootfs + FAT16 boot volume.

---

## 0. Scope reality check (read this first)

- **Xfce4 is not a display server.** It is an X11 desktop environment. "Xfce on Wayland"
  is: a Wayland compositor + **Xwayland** (hosts the X11-only bits and legacy apps) + the
  Xfce components (xfdesktop, xfce4-panel, xfce4-settings, xfce4-terminal) running
  natively Wayland (GTK3, Xfce 4.20+) or over Xwayland. This plan uses **labwc** (a
  wlroots compositor that Xfce ships as its official `xfce4-session`/`labwc-session`
  compositor) or sway as the compositor, plus Xwayland.
- **This is essentially building Linux-kernel-grade plumbing** (per-process address
  spaces, COW fork, pthreads, sockets, a `/dev`/`/proc`/`/sys` surface, DRM, evdev).
  Each kernel phase below is comparable in effort to the existing e1000/AHCI/musl work.
- **The desktop toolchain is enormous and cannot be hand-written** (mesa, glib, GTK,
  cairo, pango, Xorg, wlroots ≈ tens of millions of LOC). The project ethos is
  "hand-written kernel, real Linux userspace" (the musl milestone already established
  this split). This plan treats the **userspace as a cross-built rootfs**, not hand-authored
  code — the kernel stays hand-written C3.
- **Performance expectation under TCG (no KVM):** software GL + Xfce will render **~1–5
  fps**. Acceptance is "correct frames + real input handling", **not** smoothness. GPU
  (Phase G) is the smoothness lever and stays optional.
- **RAM budget must grow.** Xfce+GTK+Mesa+Xwayland needs ~1–2 GB. Run QEMU `-m 2048`
  (Phase C+). The kernel identity map already covers 4 GiB; the caps that must rise are
  the LX_* arena caps and the `frame_alloc` bitmap coverage (Phase A.1).

---

## 1. Current ground truth (verified in this repo)

| Area | Now | Needed for Wayland+Xfce |
|---|---|---|
| Linux processes | **one** process, one `g_linux_pml4`, one global fd table | per-process CR3, COW fork, pthreads, waitpid |
| `fork`/`clone` | `ENOSYS` (xk_linux.c3:427) | `clone` (CS) for threads, `fork` (CO) |
| sockets | **all** `ENOSYS` (xk_linux.c3:428) | `socketpair`, AF_UNIX SOCK_STREAM/SEQPKT, fd-passing SCM_RIGHTS |
| event machinery | none | `epoll_create1`/`epoll_ctl`/`epoll_wait`, `poll`/`ppoll`, `eventfd`, `timerfd_create`, `signalfd` |
| memory sharing | anonymous `mmap` only (lx_do_mmap) | `mmap MAP_SHARED` (shared page tables), `memfd_create`, `mremap`, PROT flags |
| VFS/fs | `/` FAT16 boot volume (xk_fat) | `/`+`/usr` on ext4 (Phase C), tmpfs (`/dev/shm`,`/run`), char devices (`/dev/dri/*`, `/dev/input/*`, `/dev/null`, `/dev/zero`), `/proc/self/*`, `/sys/class/drm` |
| `ioctl` | hard `-ENOTTY` (nr 16) | real ioctl dispatch: `FBIO*`, `EVIOC*`, `DRM_IOCTL_*` |
| display | kernel AquaDesktop → static shadow → VRAM 0xFD000000 blit | userland compositor mmap's the fb; DRM/KMS (G) |
| input | kernel PS/2 handler (PIC IRQ) | evdev backend: `/dev/input/event0`, `EVIOCGABS` |
| dynamic ELF | `ld-musl` + one LIBC.SO (verified) | full shared-lib resolution via musl `ld.so` (already works) — extend to a rootfs of `.so`s |
| networking | own e1000/TCP/IP, HTTP client | not on Wayland's critical path (compositor runs over AF_UNIX) |

Syscall dispatch is `xk_linux_dispatch` at `kernel/src/xk_linux.c3:311`. All kernel phases
below extend that dispatcher + `xk_umode.c3` (per-process CR3) + `xk_sched.c3` (preemption).

---

## 2. Architecture

```
                ┌────────────────────────────────────────────────┐
 xenOS kernel    │  xk_linux_dispatch (xk_linux.c3)               │
 (hand-written   │   fork/clone · sockets · epoll · ioctl · mmap  │
 C3, ring-0)     │   → xk_proc.c3: per-process CR3 + scheduler     │
                │   → xk_ext4.c3: ext4 rootfs (/usr, .so files)     │
                │   → xk_devfs:  /dev, /dev/shm, /run, /dev/input │
                └──────────────┬─────────────────────────────────┘
                               │ syscall (LSTAR)   │ mmap MAP_SHARED (fb/dma-buf)
      userspace (ring-3, static+dynamic musl)       ▼
 ┌───────────────────────────────┬──────────────────────────────────────────┐
 │  Mesa (llvmpipe/swrast EGL+GLX) │ libwayland (wl_shm first, then EGL)     │
 │  labwc / sway (wlroots compositor)                                       │
 │  Xwayland (X server as a Wayland client)                                 │
 │  Xfce: xfce4-session · xfdesktop · xfce4-panel · xfce4-settings           │
 │  apps: xfce4-terminal, mousepad, ristretto                                 │
 └──────────────────────────────────────────────────────────────────────────┘
   rootfs: static musl .so + PIE on ext4 (xk_ext4), loaded by LIBC.SO (ld-musl)
     presentation: user compositor blits wl-shm/EGL buffers → shared fb → VRAM
                   (Phase G: virtio-gpu DRM-KMS flip)
```

Render path, software milestone (D→F): client paints → wl_shm (simple, no GL first) or
EGL/llvmpipe (Phase E) → compositor → shared framebuffer mmap → kernel `fb_present`
blits the user region to VRAM. Input: kernal PS/2 → `/dev/input/event0` evdev → compositor
wl_seat → clients.

---

## Phase A — Multi-process Linux userland (the foundation)

Everything downstream is blocked on this. **Acceptance:** a dynamically-linked musl
program can `fork()` two children, each with its own address space, that talk over a
`socketpair`, rendezvous via `epoll`, and both are preemptively scheduled and reaped.

### A.1 Per-process address spaces + LRU→round-robin user scheduler
- Create `kernel/src/xk_proc.c3`: a `Proc` struct {cr3, saved_regs, state, fd_table_ptr,
  brk, mmap_cur, pid/ppid, tid, exit_status, waiting_ppid}. Move the globals from
  `xk_linux.c3` (`g_linux_pml4`, `g_user_brk`, `g_mmap_cur`, `g_fd[]`) **into** the `Proc`.
- Generalize `create_process_addrspace` (resp. `xk_umode.c3`) into a per-Proc CR3 built
  lazily on fork; `xk_set_cr3(proc.cr3)` on every userland context switch.
- Wire Linux processes into the existing preemptive scheduler (`xk_sched.c3`): the PIT ISR
  saves a clean `cs==0x18` ring-3 frame, switches CR3, and resumes the next Proc. Reuse the
  proven "never iretq a crafted frame" rule from xenos-os-dev.
- **Raise caps:** `LX_STACK_TOP`/`LX_MMAP_END`, `STACKS_BASE` (xk_alloc.c3) and the
  `frame_alloc` bitmap to cover the new RAM top (see §0). Add a `-m 2048` QEMU profile.
- **Test:** `tools/uheap.c` → three musl procs each `mmap` distinct pages, write a known
  pattern, verify no cross-perturbation; each prints its own `getpid()`; preemption bit
  flips observable via `clock_gettime` in both.
- **Verify:** serial shows pid 1,2,3 interleaved; `boot_verify.sh` still green.

### A.2 `fork`/`clone`/`exit`/`waitpid`
- Implement syscalls 56 (clone), 57 (fork), 58 (vfork), 60/231 (exit_group), 61 (wait4),
  260 (waitid).
- `fork`: build a fresh `Proc`, copy the fd table, **eager-copy** all user pages mapped in
  the parent's PT_LOAD+mmap ranges (correctness first; COW is a Phase-A.3 optimization).
  Child returns 0 from `fork`, parent returns child pid. Kernel-kernel copies via the
  byte-wise `st8`/identity-mapped copy helpers.
- `clone` with `CLONE_VM|CLONE_FS|CLONE_THREAD`: the pthread/thread path. This needs a
  shared address space (share the cr3) + distinct kernel stacks + TLS (arch_prctl per
  thread) + `gettid`. Model threads as `Proc`s sharing `cr3`, with `g_tid_addr`
  generalized from single→per-thread.
- **QEMU-iretq trap (from xenos-os-dev):** new user stacks/tasks are entered
  cooperatively (`xk_switch` + ret) or with a real interrupt frame — never an iretq into a
  hand-built frame. Thread bootstrap must enter via the same proven ring-3 entry.
- **Test:** `fork()` parent/child both write stdout (interleaved), `waitpid` reaps child
  status, a `pthread_create` (musl clone) TLS test, and a `execve-ish` fork+exec pattern.
- **Verify:** musl `posix_spawn` / fork-exec of a second binary; exit statuses correct.

### A.3 Copy-on-write (correctness preserver, then speed)
- Mark copied pages read-only in both parent and child; on a ring-3 write #PF, find the
  owning `Proc` and split the page. Add a per-Page metadata array (owner cr3 + refcount).
- Necessary before GTK/Xfce spawn many processes, else fork of a big-Mesa proc is O(GB) copy.
- **Test:** fork the compositor repeatedly (worst case), RSS stays near-constant, children
  mutate their own heap without perturbing parent.

### A.4 Sockets, epoll/eventfd/timerfd — Wayland's IPC backbone
- **AF_UNIX:** `socketpair` (nr 53), `socket` AF_UNIX (41), `bind` (49)/`listen` (50)/
  `accept` (43)/`connect` (42)/`sendmsg` (46)/`recvmsg` (47) with `SCM_RIGHTS` fd-passing
  and `SOCK_SEQPACKET`/`SOCK_STREAM` semantics. Backed by kernel queues (no real network —
  pure in-memory buffered sockets). This is **the** Wayland transport and must be rock-solid.
- **Address path:** `/run/wayland-0` must resolve — see Phase B devfs tmpfs for a real
  abstract/linkname namespace mapped into an in-memory socket table.
- **Event machinery:** `epoll_create1` (291), `epoll_ctl` (233), `epoll_wait` (232),
  `epoll_pwait` (281); poll (7)/ppoll (271); `eventfd`/`eventfd2` (290); `timerfd_create`
  (283)/`settime` (286); `signalfd`/`signalfd4` (289). Epoll must wake on the AF_UNIX
  socket readiness (the compositor's main loop is `epoll_wait` on the display socket).
- Matches the xenos-os-dev lesson: kernel-side read/write of a memory-mapped ring must be
  through extern asm helpers or the C3 compiler hoists the poll.
- **Test:** two dynamically-linked musl progs do a full `socketpair`-based request/response
  with fd-passing; an `epoll_wait` loop services two sockets concurrently; a `timerfd`
  fires on wall clock from the PIT.
- **Verify:** a small musl **echo compositor socket server** accepts a client, both driven
  purely by `epoll`, no busy spin.

### A.5 `ioctl` + shared mmap plumbing
- Replace `-ENOTTY` with a real ioctl dispatch (nr 16): route by fd backend. First real
  ioctls: `FBIOGET_VSCREENINFO`/`FBIOPUT_VSCREENINFO`/`FBIOGET_FSCREENINFO` (framebuffer),
  `EVIOCGVERSION`/`EVIOCGABS`/`EVIOCGNAME`/`EVIOCGRAB`, `DRM_IOCTL_*` (Phase G).
- `mmap MAP_SHARED` (`MAP_SHARED`) → build **shared** page mappings (one phy page mapped
  R/W into multiple address spaces, no COW) for the framebuffer / dma-buf regions.
- `mremap`, `mprotect`, `mlock` correctness; `MAP_ANONYMOUS|MAP_SHARED` (shm base for
  wl_shm without /dev/shm).

### A.6 Minimal real VFS for display servers
New `kernel/src/xk_devfs.c3` (in-memory; `/` → ext4 rootfs in Phase C, FAT16 stays the boot volume):
- **`/dev`:** directories + char devices: `/dev/null`, `/dev/zero`, `/dev/full`,
  `/dev/shm/` (tmpfs dir), `/dev/input/event0`, `/dev/dri/card0` (+`renderD128`, G).
- **`/run`:** tmpfs mount so `XDG_RUNTIME_DIR=/run` and the compositor can `bind`
  `/run/wayland-0`. Real socket file entries here.
- **`/proc`:** `/proc/self/{maps,stat,status,cmdline,exe,fd}`, `/proc/cpuinfo`,
  `/proc/meminfo`, `/proc/uptime`, `/proc/version` — glibc/GTK and the X server
  frequently read these; stub them permissively (defensive reads).
- **`/sys`:** `/sys/class/drm/card0/` minimal tree (needed by GBM for KMS; software path
  can fake it — defer to G).
- Mount table lives in xk_devfs; open/openat resolves path components across FAT+devfs.

**Phase A acceptance:** `labwc`'s dependency tree's init (glib+wayland) succeeds up to the
point it tries to `bind` a display socket — i.e. `socket()`/`bind()`/`epoll`/`/run`
all work. (Run a stripped libwayland init test, `wl_display_connect`, as the gate.)

---

## Phase B — Userland display + input surface (framebuffer to a real compositor)

**Acceptance:** a userland musl program mmaps the framebuffer, paints, and the result
appears on-screen; a second program reads `/dev/input/event0` and prints cursor motion.

- **B.1 fb mmap:** expose the runtime framebuffer (xk_fb `g_fb_w/h`, VRAM 0xFD000000 /
  SHADOW) as a MAP_SHARED region a compositor can own. Composite in userland → single
  `fb_present`/flip syscall on the shared buffer (replaces the kernel AquaDesktop blit for
  the Wayland session; keep AquaDesktop as the boot desktop / fallback).
- **B.2 evdev:** a kernel shim converts PS/2 mouse+kbd IRQs into an in-memory
  `/dev/input/event0` stream timed with `gettimeofday`; implement `EVIOCGABS` (absolute
  range = `g_fb_w/h`) and struct input_event layout (16-byte events, big-endian timeval
  s/µs + type/code/value). Verification: `cat /dev/input/event0` shows events on mouse move.
- **B.3 Pace the display loop:** the user compositor must repaint on a PIT-driven
  timerfd/`epoll` (not busy-spin) — ties Phase A.4 to rendering so animations progress
  (mirrors the earlier xk_wm `wm_tick()` lesson).

---

## Phase C — ext4 root filesystem driver

This stage serves the userspace rootfs — the hundreds of `lib*.so` / PIE binaries and
config files whose names exceed FAT16's 8.3 limit — that every later phase loads. It is
the clean replacement for the earlier "FAT32 reader" decision. FAT16 (`xk_fat`) stays as
the boot volume (kernel + minimal stage); `/` and `/usr` move onto ext4 through the
Phase-A.6 VFS.

**Acceptance:** the dynamic-musl loader reads `libwayland.so` from `/usr/lib` on a real
ext4 image; `open("/usr/lib/libwayland.so.0")+read` returns byte-correct contents; host
`e2fsck` reports the image clean; `boot_verify.sh` green. **This is the gate for Phase D.**

- **C.1 On-disk format (read path):** superblock (offset 0, first 1024 B): magic `0xEF53`,
  `s_inode_size` (256), `s_log_block_size`, `s_inodes_count`/`s_blocks_count`,
  `s_first_data_block`, feature flags (`s_feature_compat/incompat/ro_compat`) — fail loudly
  on unknown *incompatible* features. Group-descriptor tables: `blocks_per_group`,
  `inodes_per_group`, `inode_table`, inode/block bitmaps. Inodes (256 B): mode, uid/gid,
  size, `i_block[15]`; if `EXT4_EXTENTS_FL` set, `i_block[12]` holds an extent tree (header
  magic `0xF30A`, depth, entries; `ext4_extent` `ee_block`/`ee_len`/`ee_start` walk, incl.
  multi-block/sparse extents); else fall back to the direct/indirect block map. Inline and
  symlink data in `i_data` when `INLINE_DATA_FL`.
- **C.2 Directory entries:** `ext4_dir_entry` with `name_len` up to **255** (native long
  `.so` names) + `file_type`; linear scan first for the small rootfs dirs; HTree index/inode
  decode deferred (big-dir optimization). Top dirs to support: `/usr/lib`, `/usr/bin`,
  `/usr/share`.
- **C.3 Read path to the syscall layer:** extent walk → disk block → read into a
  `frame_alloc`'d buffer, feeding `lx_do_read`/`lseek`/`stat` in xk_linux.c3 with the
  inode's real size, mode, nlink, uid/gid, mtime. Handle **symlinks** (fast target inline in
  `i_block`), e.g. `/usr/lib/libc.so.1` → `libc.musl-x86_64.so.1`.
- **C.4 Read-only is acceptable:** the rootfs mounts read-only; all writes stay in the
  in-memory devfs (tmpfs `/dev/shm`, `/run`, `/proc`). ext4 journaling is skipped — build
  the image with the journal disabled (`-O ^has_journal`) and note that as a constraint.
- **C.5 Host builder `tools/mkext4.c3`** (freestanding C3, the mkfat/mkdisk pattern):
  mkfs an ext4 image from a staged root dir — superblock + group descriptors, inode/block
  bitmaps, each file's extent tree, populate `/`, `/usr/lib`, `/usr/bin`, `/usr/share` dir
  entries. Cross-verify byte-for-byte against host `mke2fs`/`dumpe2fs` and by mounting +
  `cat` on the host.
- **C.6 VFS integration:** xk_devfs mounts ext4 on `/` and `/usr`; FAT16 remains `/boot`;
  path resolution across ext4 + devfs from Phase A.6.
- **C.7 Verification:** an ext4-hosted `libwayland.so` is opened in-guest and its bytes
  match the sourced file; host `e2fsck` clean; `dumpe2fs`/`mount -o ro` round-trip on the
  host. This gate unblocks Phase D.

---

## Phase D — Wayland protocol + a booting compositor (software)

**Acceptance:** `Xwayland` is not needed here yet — instead prove the wire: a
`wl_display_connect` succeeds against a running compositor, a `wl_shell`/`zxdg` client
creates a window, and the compositor presents its wl_shm buffer to the fb.

- **D.1 libwayland:** cross-build `libwayland-server`/`libwayland-client`/`libwayland-cursor`
  & `wayland-protocols` from source into the rootfs. This is the first real userspace
  dependency — set up the cross-build pipeline now (§5).
- **D.2 wire bytes:** Wayland's protocol is fd + message framing over AF_UNIX
  (Phase A.4). Add a wire-probe host tool (`tools/wl_probe.c3`) that speaks enough of the
  wire format to GREP the handshake and confirm message alignment on the real `libwayland`.
- **D.3 compositor (wlroots-based, software first):** build **labwc** (Xfce's recommended
  compositor) or **sway**; get it to boot with a wl_shm-only backend (no GL needed):
  wl_shm → surface → `wl_surface.commit` → compositor composites the buffer to the shared
  fb. Add `wl_seat` (mouse/kbd from B.2) so a click is a real `wl_pointer` event.
- **D.4 test client:** a tiny musl program calling `wl_display_connect` +
  `wl_compositor.create_surface` + wl_shm buffer + attach/commit → window visible on screen.
- **Verify:** window appears in the QEMU screendump (`screendump` → PPM, remember the
  stdvga [B,R,G] byte-order trap from xenos-os-dev); serial log shows the wayland handshake.

---

## Phase E — Mesa software GL + real GTK apps

**Acceptance:** a GTK3 app (e.g. a hand-set GtkWindow) renders under the compositor via
EGL/llvmpipe, with correct colors and a draggable window reacting to mouse.

- **E.1 Mesa software renderer:** cross-build Mesa with `llvmpipe` (+ `swrast`) and EGL
  surfaceless + GBM; build `libEGL`, `libgbm`, `libGL` (+ GLX for Xwayland). This is the
  big build; see §5 for the pipeline. Gate: `eglinfo`/a `kmscube`-style GLES2 clear
  produces the right color.
- **E.2 wlroots EGL path:** switch compositor from wl_shm-only to EGL/GBM buffers (still
  software-rendered into shared memory, then blit to fb). Confirm wlroots' renderer
  path (pixman/software or `WLR_RENDERER=pixman`) runs — no DRM master needed yet.
- **E.3 GTK3 runtime:** glib/gdk-pixbuf/pango/cairo/atk/gtk3 + the XDG/wayland platform
  (`GDK_BACKEND=wayland`). A `GtkWindow` opens (native Wayland), a button reacts to a mouse
  click. Debug via `GDK_DEBUG`, `WAYLAND_DEBUG=1` tracing.
- **Cross-cutting dependency build order:** glib → pango/cairo/gdk-pixbuf → gtk3 → apps.

---

## Phase F — Xwayland + the Xfce4 session

**Acceptance:** `xfce4-session` boots labwc + Xwayland + xfdesktop + xfce4-panel; the
desktop background, a window manager frame, the panel, menus, and a launched
`xfce4-terminal` all render and respond to mouse/kbd.

- **F.1 Xwayland:** cross-build Xorg's Xwayland target (an X server that is a Wayland
  client). Needs GLX via E.1. Gate: an X11 client (xterm-ish) maps and renders over
  Xwayland inside the Xfce session.
- **F.2 Xfce components:** xfce4-panel, xfdesktop, xfce4-session, xfce4-settings,
  xfce4-terminal (+ xfconf for settings/dbus — note: **DBus** becomes a dependency;
  xfce uses gio/dbus; see §8 Risks).
- **F.3 session boot:** `xfce4-session` starts labwc compositor + Xwayland (`Xwayland` is
  auto-launched by wlroots on first X client) + xfdesktop (background/menus) + panel.
  `XDG_SESSION_TYPE=wayland`, `XDG_RUNTIME_DIR=/run`,
  `XDG_SESSION_DESKTOP=xfce`, `WAYLAND_DISPLAY=wayland-0` all exported.
- **F.4 verify the desktop:** screendump shows wallpaper + taskbar + a window; mouse
  moves windows and hoover-highlights a menu; `xfce4-terminal` draws a real prompt.
  Drive via the existing mouse_move.sh/boot_verify.sh harnesses (extended with
  `-device virtio-gpu` only in G).

---

## Phase G — virtio-GPU / DRM-KMS (follow-on optimization, optional)

**Acceptance:** EVANG compositor composites via real KMS flips on the virtio-gpu; GPU path
replaces the shared-fb blit; frame rate rises from 1–5 fps toward interactive.

- **G.1 virtio-gpu PCI driver:** `kernel/src/xk_virtio_gpu.c3` — reuse PCI bus-master path
  (xk_pci.c3), virtqueue ring + MMIO; implement enough of virtio-gpu (scanout, resource
  create/flush) to present a dumb framebuffer.
- **G.2 DRM surface in kernel:** `/dev/dri/card0` + `renderD128`, the `DRM_IOCTL_MODE_*`
  (GETRESOURCES, GETCONNECTOR, GETCRTC, ADDFB, PAGE_FLIP) + GEM (`DRM_IOCTL_GEM_CREATE`,
  `PRIME_FD_TO_HANDLE`) ioctls backed by virtio-gpu.
- **G.3 Mesa virtio_gpu + GBM:** build Mesa's `virtio_gpu` Gallium driver; GBM picks
  `virtio-gpu`; compositor `wlroots` uses the GBM/KMS backend with real page flips; keep
  software rendering as the fallback `WLR_RENDERER` path.
- **G.4 settle `/sys/class/drm`** so GBM discoverability works; remove Phase-B/D "fake"
  sysfs (or keep soft links for fallback).

---

## 5. Cross-cutting: the userspace rootfs build pipeline

This is as much a foundation as any kernel phase; build it in Phase D.1 and grow it.

- **Purpose:** produce a **static-musl rootfs** (`.so`s + PIE binaries + config) laid out
  on the **ext4 rootfs (Phase C)**, loadable by the proven `LIBC.SO`/`ld-musl` dynamic path
  (`linux-userland-dynamic.md`). Do **not** hand-write mesa/GTK.
- **Toolchain targets:** `musl-gcc -static-pie -O2` (PIE for the shared-lib rootfs,
  `-no-pie` already proven for mains). One `.so`/binary per FAT file; `LD_LIBRARY_PATH`
  unneeded if all libs are DT_NEEDED and present under `/usr/lib` on the ext4 rootfs.
- **Source/build orchestration** (delegate to a reproducible subagent-driven build):
  circtra/`.just`/a bash matrix: fetch pinned tarballs → configure each with `--host=x86_64-
  linux-musl --without-x11` (where sensible) → `musl-gcc` wrap → install to a staged root.
  Order: zlib → libffi → glib → wayland/protocols → libxkbcommon → pixman →
  cairo → pango → gdk-pixbuf → gtk3 → fontconfig/freetype/harfbuzz → wayland-utils →
  wlroots → labwc/sway → **mesa** (llvmpipe, E) → Xwayland (F) → xfce* (F).
- **Rootfs builder:** the ext4 image (Phase C) is assembled by `tools/mkext4.c3` from a
  staged root dir; `tools/mkfat.c3` stays for the small FAT16 boot volume (kernel + a
  minimal stage). The long-`.so`-name problem that once motivated a FAT32 reader is resolved
  by adopting ext4 as the rootfs.
- **Verification per package:** a tiny musl `dlopen` harness calls its `main`/init and
  prints version; the ext4 image stays within build limits; boot time measured.

> Edited: the previous "FAT32 reader" recommendation is superseded by **Phase C — the
> ext4 rootfs driver**, which natively handles the long `libwayland`/`libgtk-3.so` names.
> FAT16 remains only the boot volume.

---

## 6. File map (xenOS kernel side)

| File | Change |
|---|---|
| `kernel/src/xk_proc.c3` | **new** — Proc struct, per-proc CR3, user-scheduler integration |
| `kernel/src/xk_linux.c3` | extend `xk_linux_dispatch` for fork/clone/sockets/epoll/ioctl/mmap-shared |
| `kernel/src/xk_umode.c3` | generalize addrspace/CR3 per Proc; shared-mapping builder |
| `kernel/src/xk_devfs.c3` | **new** — /dev, /dev/shm, /run tmpfs, /proc, /sys stubs |
| `kernel/src/xk_evdev.c3` | **new** — PS/2 → input_event stream, /dev/input/event0, EVIOCIOCTL |
| `kernel/src/xk_fb.c3` | expose fb as MAP_SHARED user region; keep blit |
| `kernel/src/xk_sched.c3` | preempt Linux procs (cs==0x18 gate already present) |
| `kernel/src/xk_ext4.c3` | **new** (Phase C) — ext4 superblock/groups/inodes/extents/dir read; mounts `/`+`/usr` |
| `tools/mkext4.c3` | **new** (Phase C) — host ext4-from-staged-root builder (mkfat/mkdisk pattern) |
| `kernel/src/xk_virtio_gpu.c3` | **new** (Phase G) — virtio-gpu driver + DRM ioctls |
| `tools/mkfat.c3` | FAT16 boot volume only (kernel + minimal stage); rootfs moves to `mkext4` |
| `build.sh`, `run.sh`, `boot_verify.sh` | `-m 2048`, rootfs staging, virtio-gpu device, Wayland session harness |

---

## 7. Test / validation strategy

- **Every kernel phase:** extend the scoped musl test binaries (`tools/u*.c`) + the
  `boot_verify.sh` headless harness and an added `wayland_verify.sh` (boot → assert the
  compositor's display socket exists → launch a wl client → screendump → assert the
  window's color at expected coords with the [B,R,G] byte-order parity).
- **Wayland wire-level (`tools/wl_probe.c3`)**: independent parser that confirms the
  handshake and message frames — grounds the compositor debugging like the TLS oracle.
- **Syscall coverage check:** `strace` each target on host to enumerate the exact syscalls
  (proven pattern from `linux-userland-musl.md`), then close each gap deliberately.
- **Filesystem (Phase C):** host `mke2fs`/`dumpe2fs`/`e2fsck` cross-check the `mkext4`
  image; mount it read-only on the host and `cat` a sourced file; in-guest open/read of the
  same path returns identical bytes.
- **Screenshot-driven:** reuse `screendump` validation; TCG slowness means use
  screenshots, not wall-clock assertions.

---

## 8. Risks, tradeoffs, open questions

- **Scale/effort:** this is a multi-month program. De-risk by keeping every Phase a green
  milestone; do not start Phase D onward until the multiprocess foundation (A) and the
  ext4 rootfs (C) are demonstrably solid.
- **COW is hard; eager-copy fork is a safe v1.** Ship A.2 eager, optimize with A.3 only if
  the mesa fork cost is measurable and blocking.
- **DBus is effectively mandatory** for Xfce (xfconf/gio). This adds daemon-bootstrapping
  to the userland — scope it in Phase F.1 explicitly; alternatively run Xfce with
  `XFCONF_` point to a static config to defer dbus (note tradeoff).
- **PIE vs static** for hundreds of `.so`/bin — the dynamic loader proven is musl's, which
  already handles full shared resolution; keep `-static-pie` mains.
- **Rootfs long names solved by ext4:** Phase C replaces the earlier FAT32-reader idea;
  FAT16 stays only the boot volume. Keep `mkext4` byte-compatible with host `mke2fs`
  (verify with e2fsck/dumpe2fs) so the same image is readable both on the host and in-guest.
  Read-only + journal-disabled rootfs is the committed v1; a writable `/usr` would need
  ext4 journal replay (defer).
- **Virtio-GPU is a second kernel graphics subsystem** — keep it explicitly optional and
  non-blocking; software-first is the committed milestone.
- **Bandwidth under TCG:** even software rendering contends for the single core. Keep the
  session minimal (no compositing transparency effects initially).

## Open decisions (resolve before Phase D)
1. Compositor base: **labwc** (Xfce's official Wayland compositor) vs **sway** — recommend labwc for Xfce session fidelity.
2. ~~FAT32 reader~~ → resolved: **ext4 rootfs driver added (Phase C)**. Remaining: rootfs
   read-only + journal-disabled is acceptable (recommended) vs implementing ext4 journal
   replay for a writable `/usr`.
3. Whether to attempt DBus in F.1 or defer with a static xfconf setup.