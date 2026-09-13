# Build and run

## Prerequisites — almost none

The build is **self-bootstrapping and user-agnostic**. There is no user-specific
or hardcoded toolchain path anywhere: all generated state lives under a
project-local `.toolchain/` directory, and missing host tools are auto-installed.

Run this once (or any time a tool reports missing):

```sh
./scripts/bootstrap.sh          # installs missing host tools + the C3 compiler
```

`bootstrap.sh` auto-detects your OS (apt / dnf / pacman / zypper / apk / brew),
installs the host build tools (nasm, binutils, e2fsprogs, meson, ninja,
pkg-config, autotools, QEMU, xorrisofs, musl-gcc, patchelf), and downloads the
`c3c` compiler into `.toolchain/bin` — no root needed for `c3c`. If it cannot
self-elevate for a system package it prints the exact one `sudo` command to run.

Other helpers:

```sh
./scripts/bootstrap.sh doctor    # report what is present / missing, change nothing
./scripts/bootstrap.sh sysroot   # ALSO cross-build the musl userspace sysroot
```

## Commands

```sh
./build.sh
./run.sh
./run.sh serial
qemu-system-x86_64 -cdrom build/xenos.iso -m 256 -boot d
```

`build.sh` auto-runs `bootstrap.sh host` up front (idempotent), so a fresh
machine builds `build/xenos.img` and, when `xorrisofs` is installed,
`build/xenos.iso`. It builds host tools, creates FAT and ext4 images, embeds
user programs, compiles the kernel, and links it at 1 MiB.

## Configuration inputs

All paths default to a **project-local toolchain** under `.toolchain/`, so
different users / machines get a working build with no hand-editing. Override
any of these to share a toolchain across checkouts (e.g. `/opt/xenos`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `XENOS_TOOLCHAIN` | `$ROOT/.toolchain` | Root of all generated toolchain state. |
| `XENOS_CROSSROOT` | `$XENOS_TOOLCHAIN/sysroot` | Cross-musl sysroot (`CROSSROOT`/`SYS` alias). |
| `XENOS_SRC`       | `$XENOS_TOOLCHAIN/src` | Cross-build source checkout dir (`SRC` alias). |
| `XENOS_INC`       | `$XENOS_TOOLCHAIN/linuxinc` | Linux-header stubs for musl (`INC` alias). |
| `XENOS_ROOTFS`    | `$XENOS_TOOLCHAIN/rootfs-libs` | Staged userspace `.so` tree (`ROOTFS` alias). |
| `XENOS_HOSTPKG`   | `$XENOS_TOOLCHAIN/hostpkg` | Host-tool package mirror (`HOSTPKG` alias). |
| `C3C_VERSION`     | `0.8.3` | c3c release pin fetched by `bootstrap.sh`. |
| `XENOS_AI_TOKEN`  | unset | Token placed into the generated FAT image; never commit a value. |

Legacy names (`CROSSROOT`, `STAGE_SO`, `SYS`, `SRC`, `INC`, `ROOTFS`, `HOSTPKG`)
are still honored as aliases, but the `XENOS_*` set is authoritative.

For focused checks, see [Verification](verification.md). Remove `build/` to
force a clean artifact rebuild; it is generated and is not source input.