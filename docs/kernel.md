# Kernel guide

## Entry and execution model

`xk_main.c3` is linked first so the kernel entry remains at 1 MiB. `xk_core.c3`
performs system boot. Interrupt and timer code lives in `xk_intr.c3` and the
assembly runtime; scheduling is coordinated by `xk_sched.c3`.

The scheduler uses fixed global state and a hybrid context-switch strategy.
Treat per-task stack locals as short-lived across rescheduling; retain durable
task state in the appropriate global table or module-owned storage.

## Subsystem boundaries

* **Hardware:** ATA/AHCI, PCI, RTC, PS/2 input, framebuffer, and interrupt
  code own port/MMIO interactions.
* **Storage:** FAT and ext4 expose read paths. Ext4 is intentionally read-only.
* **Process service:** allocation, memory helpers, ring-3 setup, Linux-ELF
  support, and syscall dispatch form the user execution boundary.
* **Desktop:** window manager, app/shell host, and Wayland protocol code share
  framebuffer and input state but retain separate responsibilities.
* **Network and AI:** Ethernet/IP/TCP/HTTP/TLS/crypto provide a layered client
  path used by the AI configuration, client, chat, and agent modules.

Use [Kernel module reference](kernel-modules.md) before moving code between
modules. It is the ownership index; the source browser is the implementation
index.

## C3 build constraints

Compile freestanding code with no standard library and baseline x86 options:

```sh
c3c compile-only --target elf-x64 --no-entry --use-stdlib=no \
  --x86cpu=baseline --x86vec=none
```

Avoid adding SSE/AVX assumptions. Follow existing C3 conventions for aliases,
pointer-to-array calls, and lowercase mutable globals.
