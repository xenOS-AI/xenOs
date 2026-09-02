# xenOS

A true from-scratch hobby operating system written in **C3**, booting to a
graphical desktop in **QEMU**. Everything is hand-written — bootloader, kernel,
drivers, memory helpers, an own X-equivalent display server / window manager,
and a shell — with **zero borrowed code**.

## Documentation

The [documentation wiki](docs/index.md) covers the architecture, boot path,
kernel module ownership, build/run workflow, userspace tools, verification,
and contribution process. Generate the searchable Doxygen source reference
with `doxygen Doxyfile`; it writes to `build/docs/doxygen/html/` and is not
committed.

## What it does (all verified under QEMU)

* Boots from a 512-byte boot sector through a hand-written long-mode trampoline
  (own GDT, page tables, native ATA PIO driver) into a freestanding C3 kernel.
* Interrupts: IDT from 48 hand-written asm stubs, PIC remap, PIT 100Hz timer,
  exception dumping.
* PS/2 **keyboard** and **mouse** drivers (IRQ1 / IRQ12).
* VESA **framebuffer** (1920x1080x32) with a RAM shadow buffer + dirty-rect blit
  (TCG's VRAM is slow, so only damaged regions are copied) and a hand-drawn
  8x8 bitmap font.
* Preemptive round-robin **multitasking** — the PIT timer preempts every task
  at 100 Hz (~10 ms slice; verified: busy-looping demo tasks with *no* yield
  interleave A/B/C once per second while the desktop/shell stay responsive).
* A **window manager** (own X-equivalent): titled windows (active/inactive),
  click-to-focus, close button, drag-by-title, plus a dock.
* GUI apps: an animated demo window and a clock, and a **terminal window
  running an interactive shell** (`sh`) with `ls/cat/echo/help/about/uname/ps/clear`.
* A tiny in-memory **VFS** with a few files.
* **Real FAT16 filesystem on disk** — the host tool `tools/mkfat.c3` builds an
  8 MiB FAT16 volume (`build/fat.img`) populated with real files; the kernel
  mounts it at boot by reading the boot sector over a from-scratch **ATA PIO
  driver** (secondary IDE channel), and the shell `ls`/`cat` list and read the
  actual on-disk files (following the FAT cluster chain). No emulation, no
  BIOS disk calls — the driver is hand-written C3.
* **Syscalls** via an `int 0x80` gate (vector 128): `getpid`, `ticks`, `puts`
  (exercised by the shell's `sysc` builtin) — the ABI future ring-3 processes use.
* **Ring-3 userland with a DISTINCT per-process address space** — DPL-3 user
  segments + a TSS; the kernel drops to CPL3 in an embedded program
  (`user/sys_prog.asm`) that talks to the kernel only via `int 0x80`
  (gate DPL=3): `SYS_UMSG`, an unknown-syscall that the kernel rejects
  (protection), and `SYS_EXIT` (returns to ring-0 and resumes the desktop).
  Each program gets its OWN page tables (a separate CR3, e.g. 0x112000 vs the
  kernel's 0x9000) built by `create_process_addrspace()`: an identity 0..4GiB
  map where only the process's own 2MiB page is U/S and every other PDE is
  supervisor — so the kernel stays isolated and the shared kernel tables are
  never made user-accessible.
* Freestanding `memset/memcpy/memmove/memcmp` exported under exact linker names.
* **PCI + AHCI (SATA) driver** — the PCI probe enumerates the bus and now detects
  the SATA host controller (class 01.06, e.g. Intel ich9-ahci 8086:2922); the
  from-scratch `xk_ahci.c3` resets and enables the HBA, brings up each live SATA
  link (PxSSTS DET=3), and issues real device commands through a command header,
  a host-to-device FIS and a PRDT (count = 7 devices under QEMU once the AHCI
  controller is attached).

## Known limitations
- **Preemption is not interrupt-safe for arbitrary kernel code**: the timer
  preempts at a defined scheduler point (task resume via its real frame), and
  a preempted task's own stack locals do not reliably survive the switch — long-
  lived per-task state lives in module globals. (A hand-crafted new-task IRET
  frame is rejected by QEMU 11's iretq, so the hybrid xk_switch + real-frame
  iretq switch described in `kernel/src/xk_sched.c3` is used.)
- **One ring-3 process at a time**: the embedded `sys_prog.asm` is the single
  user program; there is no process table / fork / exec yet, so distinct-CR3
  support is demonstrated by that one program (one address space built at boot).
  Generalizing to N processes with a switch-on-schedule is future work.
- **AHCI read returns empty on QEMU**: the SATA host controller is initialized,
  the link is brought up and device commands are accepted (DET=3, PxCI clears,
  DHRS asserts, no drive error), but the sector data DMA path back into the guest
  PRD buffer does not yet land (buffers read back zero; the PRD descriptor is
  correct). This is the known remaining piece of the AHCI driver.

## Build & run

Requires: `c3c` (0.8.x, `sudo pacman -S c3c` on Arch), `nasm`, `clang/ld`,
`python3`, `qemu-system-x86_64` (`xorrisofs` for the bootable ISO).

```sh
./build.sh      # assembles boot stages, compiles+links the C3 kernel, builds xenos.img AND xenos.iso
./run.sh        # boot the graphical desktop in a QEMU window
./run.sh serial # headless boot with the serial console in the terminal

# bootable ISO (built by ./build.sh when xorrisofs is present)
qemu-system-x86_64 -cdrom build/xenos.iso -m 256 -boot d
```

`./build.sh` produces both a raw disk image (`build/xenos.img`) and a bootable
El Torito CD-Rom (`build/xenos.iso`). The ISO's boot image is a hand-written
no-emulation loader (`iso/iso_boot.asm`, assembled and wrapped with our own
`mkbootimg` C3 tool plus `xorrisofs` for the ISO9660 container); it copies the
kernel to 0x100000 and enters long mode the same way the disk boot does. Booting
the ISO has no VESA framebuffer, so the kernel falls back to a serial console.

The desktop boots to a taskbar/dock with three windows. Click the terminal
(title bar) to focus it and start typing shell commands (e.g. `ls`, `cat motd`,
`echo hello xenOS`, `help`). Drag any window by its title bar; the X button
closes it.

## Layout

```
boot/
  stage1.asm       512-byte real-mode boot sector (VBE, loads stage2, BootInfo)
  stage2.asm       long-mode trampoline: GDT, page tables, own ATA PIO kernel load
kernel/
  linker.ld        flat 1 MiB layout; xk_main first so entry == 0x100000
  src/
    asm_runtime.asm  low-level asm: port I/O, interrupt stubs, context switch xk_switch
    xk_main.c3       entry (zeroes BSS, calls xk_boot)
    xk_core.c3       boot, COM1 serial, BootInfo, framebuffer fill
    xk_intr.c3       IDT/PIC/PIT, exception + IRQ dispatch
    xk_kbd.c3        PS/2 keyboard (scancode set 1 -> ASCII, shift)
    xk_mouse.c3      PS/2 mouse (packets -> x/y/buttons; 8042 aux-IRQ setup)
    xk_fb.c3         shadow framebuffer: pixels, rects, text, blit
    xk_font.c3       8x8 font data (generated by tools/mkfont.py)
    xk_wm.c3         window manager: titles, focus, drag, close, dock, z-order
    xk_apps.c3       terminal (shell host), clock, animated demo
    xk_sched.c3      cooperative round-robin scheduler + thread_create/yield
    xk_shell.c3      command interpreter + tiny VFS catalog
    xk_mem.c3        freestanding memset/memcpy/memmove/memcmp
tools/
  mkfont.py    builds kernel/src/xk_font.c3 from a hand-drawn 8x8 font
                (dev-time only; xk_font.c3 is committed so the build needs no Python)
  host_start.asm  freestanding host runtime (_start + Linux syscalls) for the C3 tools
  mkdisk.c3    C3 host tool: assembles the bootable disk image (no libc)
  mkbin.c3     C3 host tool: embeds the ring-3 program as xk_uprog.c3 (no libc)
  mkbootimg.c3 C3 host tool: builds the El Torito no-emulation boot image (no libc)
iso/
  iso_boot.asm  hand-written no-emulation ISO boot loader (copies kernel to
                0x100000, enters long mode; wrapped into xenos.iso by build.sh)
```
The build pipeline itself is hand-written C3 too: `mkdisk.c3`, `mkbin.c3`, and
`mkbootimg.c3` are freestanding host programs (no libc) that build.sh compiles
and links. The only external tools are the compiler/assembler/linker (`c3c`,
`nasm`, `ld`, `objcopy`) and `xorrisofs` (ISO9660 container for the bootable
ISO); no OS can avoid a toolchain. `python3` is not used by the build.

Memory map (physical): stage1 @0x7C00, BootInfo @0x7000, stage2 @0x8000, page
tables/GDT @0x9000–0xF000, kernel stack @0x90000, kernel @0x100000, task stacks
@0x3000000, shadow framebuffer @0x2000000, QEMU stdvga LFB @0xFD000000.

## C3 notes (hard-won)

* Freestanding: `c3c compile-only --target elf-x64 --no-entry --use-stdlib=no
  --x86cpu=baseline --x86vec=none` — the last two flags stop LLVM emitting SSE/AVX
  that `#UD` on QEMU's default CPU.
* Entry placement: the entry function must be the FIRST in its object, linked
  first, so `call 0x100000` lands on it.
* Function-pointer types need an `alias` (`alias H = fn void(X);`), assigned with `&fn`.
* Mutable module globals must be lowercase (all-caps = comptime const/type).
* Arrays are `T[n] x`, no implicit decay — pass `&x[0]` to pointers.
* `if/else` bodies must be braced even for single statements.
