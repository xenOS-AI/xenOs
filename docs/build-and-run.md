# Build and run

## Prerequisites

The normal build expects `c3c` 0.8.x, `nasm`, `ld`/`objcopy`, Python 3,
`mke2fs`, and QEMU. `xorrisofs` enables ISO output. Optional musl and cross
sysroot inputs enable the Linux/userspace experiments; a missing optional tool
causes the build script to stage placeholder or reduced artifacts where noted.

## Commands

```sh
./build.sh
./run.sh
./run.sh serial
qemu-system-x86_64 -cdrom build/xenos.iso -m 256 -boot d
```

`build.sh` produces `build/xenos.img` and, when `xorrisofs` is installed,
`build/xenos.iso`. It also builds host tools, creates FAT and ext4 images,
embeds user programs, compiles the kernel, and links it at 1 MiB.

## Configuration inputs

| Variable | Default | Meaning |
| --- | --- | --- |
| `CROSSROOT` | `/home/timo/crossmusl/sysroot` | Cross-build sysroot used for userspace dependencies. |
| `STAGE_SO` | `/home/timo/crossmusl/rootfs-libs/usr/lib` | Shared-library staging directory. |
| `XENOS_AI_TOKEN` | unset | Token placed into the generated FAT image; never commit a value. |

For focused checks, see [Verification](verification.md). Remove `build/` to
force a clean artifact rebuild; it is generated and is not source input.
