# Kernel module reference

This is the ownership index for every hand-written kernel source module.
Generated embedded blobs are documented with their generators in
[Userspace and host tools](userspace-and-tools.md).

## Bootstrap, execution, and memory

| Module | Responsibility |
| --- | --- |
| `xk_main.c3` | Kernel entry point and BSS initialization. |
| `xk_core.c3` | Boot sequencing, serial output, BootInfo, and basic framebuffer setup. |
| `xk_intr.c3` | IDT, PIC/PIT setup, exceptions, and IRQ dispatch. |
| `asm_runtime.asm` | Port I/O, interrupt stubs, and low-level context-switch support. |
| `xk_sched.c3` | Task creation, yielding, and round-robin scheduler state. |
| `xk_mem.c3` | Freestanding linker-name memory primitives. |
| `xk_alloc.c3` | Kernel allocation helpers. |
| `xk_sys.c3` | `int 0x80` syscall dispatch and syscall-facing services. |
| `xk_umode.c3` | TSS, user mappings, and transition to the ring-3 demonstration. |
| `xk_linux.c3` | Linux ELF loading and compatibility-oriented userspace support. |

## Hardware and graphics

| Module | Responsibility |
| --- | --- |
| `xk_kbd.c3` | PS/2 keyboard initialization and scancode-to-ASCII handling. |
| `xk_mouse.c3` | PS/2 auxiliary-device setup and three-byte mouse packets. |
| `xk_fb.c3` | Shadow framebuffer drawing, text, dirty rectangles, and VRAM blits. |
| `xk_font.c3` | Generated 8×8 font table consumed by framebuffer text drawing. |
| `xk_wm.c3` | Window focus, z-order, drag, close controls, and dock behavior. |
| `xk_apps.c3` | Built-in terminal, clock, and demonstration applications. |
| `xk_shell.c3` | Interactive shell and small virtual file catalog. |
| `xk_pci.c3` | PCI configuration-space enumeration. |
| `xk_rtc.c3` | CMOS wall-clock reads. |
| `xk_ata.c3` | IDE/ATA PIO disk access. |
| `xk_ahci.c3` | SATA AHCI controller/link setup and command issue path. |

## Filesystems and protocol services

| Module | Responsibility |
| --- | --- |
| `xk_fat.c3` | FAT16 mount, directory traversal, and cluster-chain reads. |
| `xk_ext4.c3` | Read-only ext4 metadata, path, extent, and file-reading support. |
| `xk_wl.c3` | Kernel Wayland compositor protocol and Unix-socket-facing behavior. |
| `xk_net.c3` | Network-device and Ethernet-level support. |
| `xk_ip.c3` | IPv4 packet construction and parsing. |
| `xk_tcp.c3` | TCP connection and stream state. |
| `xk_http.c3` | HTTP request/response handling for clients. |
| `xk_tls.c3` | TLS handshake and record-path logic. |
| `xk_sha256.c3` | SHA-256 primitives used by TLS. |
| `xk_aes.c3` | AES and authenticated-encryption primitives used by TLS. |

## AI feature path

| Module | Responsibility |
| --- | --- |
| `xk_ai_cfg.c3` | AI endpoint/configuration handling. |
| `xk_ai_client.c3` | Remote AI request client. |
| `xk_chat.c3` | Chat request and response presentation logic. |
| `xk_agent.c3` | Agent-oriented orchestration on top of chat/client services. |

## Generated kernel inputs

| File | Generator / source |
| --- | --- |
| `xk_uprog.c3` | `tools/mkbin.c3` embeds `user/sys_prog.asm`. |
| `xk_ublob.c3` | `tools/mkbin.c3` embeds a built userspace test binary. |
| `xk_dynblob.c3` | `tools/mkbin.c3` embeds a dynamic userspace test binary. |

Do not edit generated inputs directly. Rebuild them through `build.sh` or the
corresponding generator.
