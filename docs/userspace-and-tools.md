# Userspace and host tools

## Userspace

`user/sys_prog.asm` is the minimal ring-3 program embedded into the kernel. It
uses the `int 0x80` ABI to prove the privilege boundary, including normal and
rejected syscall cases. It is not a general process runtime.

The C files prefixed `u_` under `tools/` are target-side, musl-built probes.
They exercise Linux-compatible facilities implemented by the kernel: ELF
loading, filesystems, memory mapping, sockets, polling/epoll, shared memory,
and the kernel Wayland compositor. They are build inputs, not hand-written
kernel userspace libraries.

## Image and code generators

| Tool | Purpose |
| --- | --- |
| `mkdisk.c3` | Assemble the raw bootable disk image. |
| `mkbootimg.c3` | Wrap the ISO loader and kernel as an El Torito boot image. |
| `mkfat.c3` | Create the FAT16 data volume and stage selected files. |
| `mkbin.c3` | Convert binary inputs into generated C3 embedded arrays. |
| `mkfont.py` | Generate the committed C3 8×8 font table. |
| `ext4read.c3` / `ext4_probe.py` | Validate the read-only ext4 path against a host image. |

`host_start.asm` supplies the libc-free Linux host entry/runtime used by C3
tools. The crypto and TLS C3 tools are host self-tests or interoperability
programs; `ai_mock.c3` and `ai_mock_py.py` provide local AI-provider test
servers. `ref_gcm.c` is a host reference comparison utility.

## Scripts

| Script | Purpose |
| --- | --- |
| `scripts/boot_verify.sh` | Boot-oriented QEMU verification. |
| `scripts/ai_selftest.sh` | AI stack self-test. |
| `scripts/ai_connectivity_test.sh` | AI connectivity test. |
| `scripts/mouse_alive_test.sh` / `mouse_move.sh` | Input/liveness checks. |
| `scripts/crossbuild_deps.sh` | Build static musl userspace dependencies. |
| `scripts/crossbuild_shared.sh` | Build/stage shared musl dependencies. |

Treat cross-build outputs and staged roots as generated state. Never commit
credentials passed through build environment variables.
