# Architecture

## Layers

| Layer | Location | Responsibility |
| --- | --- | --- |
| Boot | `boot/`, `iso/` | Load the kernel, establish long mode, and pass boot information. |
| Kernel | `kernel/src/` | Scheduling, memory, interrupts, devices, filesystems, networking, graphics, and syscall services. |
| Ring-3 sample | `user/sys_prog.asm` | Exercises the x86_64 `int 0x80` user/kernel boundary. |
| Host tools | `tools/` | Build images, embed binaries, generate fonts, and run protocol/self-tests. |
| Build orchestration | `build.sh`, `scripts/` | Compile freestanding components, stage filesystems, and verify a QEMU boot. |

## System contracts

* The kernel is hand-written C3 and is freestanding: it does not depend on a
  hosted C library.
* Kernel resources use fixed global tables, including scheduler (`g_up[]`) and
  socket (`g_sock[]`) state. Capacity is therefore a design constraint, not an
  allocation policy.
* Kernel file descriptors are typed. Callers must preserve the descriptor kind
  and use the matching subsystem operations.
* The ext4 implementation is read-only. Image creation and mutation happen on
  the host during the build.
* The syscall ABI is x86_64 via `int 0x80`; ring-3 code must use the ABI rather
  than calling kernel symbols directly.
* The display path uses a RAM shadow framebuffer and copies only dirty regions
  to VESA VRAM, avoiding costly full-frame writes in QEMU TCG.

## Data and control flow

Firmware enters the stage-1 sector, which loads stage 2. Stage 2 builds the
long-mode environment, loads the kernel at 1 MiB, and transfers control to the
kernel entry. Kernel boot configures interrupts and devices, then runs the
scheduler, window manager, shell, and optional userspace demonstrations. See
[Boot and memory map](boot.md) for addresses and [Kernel guide](kernel.md) for
the owning modules.
