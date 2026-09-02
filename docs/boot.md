# Boot and memory map

## Disk boot path

1. BIOS loads `boot/stage1.asm` at `0x7c00`.
2. Stage 1 collects VBE/boot information and loads stage 2 at `0x8000`.
3. `boot/stage2.asm` configures the GDT and page tables, loads the kernel via
   ATA PIO, enters 64-bit long mode, and calls the kernel at `0x100000`.
4. `xk_main.c3` clears BSS and hands off to the kernel boot routine.

The ISO follows the same long-mode destination through `iso/iso_boot.asm`,
which is wrapped into an El Torito no-emulation image by `tools/mkbootimg.c3`.
The ISO path has no VESA framebuffer and therefore uses serial fallback.

## Physical layout

| Region | Address/range | Owner |
| --- | --- | --- |
| Stage 1 | `0x7c00` | BIOS boot sector |
| BootInfo | `0x7000` | Stage 1 to kernel handoff |
| Stage 2 | `0x8000` | Long-mode trampoline |
| Page tables and GDT | `0x9000–0xf000` | Stage 2 |
| Kernel stack | `0x90000` | Kernel early boot |
| Kernel image | `0x100000` | Linker/kernel entry |
| Shadow framebuffer | `0x2000000` | Framebuffer subsystem |
| Task stacks | `0x3000000` | Scheduler |
| VESA LFB | `0xfd000000` | QEMU stdvga framebuffer |

Changing an address requires reviewing the assembler, linker script, and the
owning kernel subsystem together; these values form an ABI between stages.
