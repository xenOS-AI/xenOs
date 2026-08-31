#!/usr/bin/env bash
# xenOS build script - hand-written toolchain
# Builds the bootloader + kernel and assembles a bootable raw disk image.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

BOOT="$ROOT/boot"
KERNEL="$ROOT/kernel"
SRC="$KERNEL/src"
OUT="$ROOT/build"
mkdir -p "$OUT"

echo "[build] stage1 boot sector"
nasm -f bin -o "$OUT/stage1.bin" "$BOOT/stage1.asm"
echo "[build] stage2 long-mode trampoline"
nasm -f bin -o "$OUT/stage2.bin" "$BOOT/stage2.asm"

build_host_tool() {   # build a freestanding C3 host tool (no libc)
    local name="$1"
    mkdir -p "$OUT/hostobj"
    rm -f "$OUT/hostobj"/obj/linux-x64/*.o "$OUT/hostobj"/obj/elf-x64/*.o
    ( cd "$OUT/hostobj" && c3c compile-only --no-entry --use-stdlib=no --x86cpu=baseline --x86vec=none -O2 -g0 "$ROOT/tools/$name.c3" )
    local obj
    obj=$(find "$OUT/hostobj/obj" -name "$name.o" | head -1)
    ld -m elf_x86_64 -o "$OUT/$name" "$obj" "$OUT/host_start.o"
}
echo "[build] host tool runtime (_start + syscalls)"
nasm -f elf64 -o "$OUT/host_start.o" "$ROOT/tools/host_start.asm"
echo "[build] mkdisk image assembler (C3, freestanding)"
build_host_tool mkdisk
echo "[build] mkbin embedder (C3, freestanding)"
build_host_tool mkbin
echo "[build] mkbootimg (C3, freestanding; builds the El Torito boot image)"
build_host_tool mkbootimg
echo "[build] mkfat FAT16 data volume (C3, freestanding)"
build_host_tool mkfat
echo "[build] ext4read ext4 rootfs read-path self-test + test image (Phase C)"
build_host_tool ext4read
mkdir -p "$OUT/rootfs" "$OUT/rootfs/usr/lib"
printf 'hello from ext4 rootfs xenOS\n' > "$OUT/rootfs/MOTD.TXT"
printf '# ext4 build test\n' > "$OUT/rootfs/README.md"
printf 'libwayland bytecheck\x00\x01\x02\n' > "$OUT/rootfs/usr/lib/libwayland.so.0"
cp "$OUT/rootfs/MOTD.TXT" "$OUT/rootfs/usr/lib/motd.txt"
ln -sf libwayland.so.0 "$OUT/rootfs/usr/lib/libwayland.so"
rm -f "$OUT/rootfs.ext4"
mke2fs -q -F -t ext4 -b 1024 -O ^has_journal,^metadata_csum,^64bit,^uninit_bg,^flex_bg,^dir_index,^sparse_super,^resize_inode,^extra_isize,^huge_file,^large_file,^ext_attr,^dir_nlink -d "$OUT/rootfs" "$OUT/rootfs.ext4" 4096
echo "    rootfs.ext4 = $(stat -c%s "$OUT/rootfs.ext4") bytes"
echo "[build] ai_mock host AI provider server (C3, freestanding)"
build_host_tool ai_mock
echo "[build] sha256_test TLS-hash self-test (C3, freestanding)"
build_host_tool sha256_test
echo "[build] tls_clienthello TLS interop emitter (C3, freestanding)"
build_host_tool tls_clienthello
echo "[build] aesgcm_test AES-128-GCM vector self-test (C3, freestanding)"
build_host_tool aesgcm_test
echo "[build] p256_test P-256 scalar-mult self-test (C3, freestanding)"
build_host_tool p256_test
echo "[build] tls_handshake TLS1.2 ECDHE-RSA-AES128-GCM client vs openssl s_server"
build_host_tool tls_handshake
rm -f "$OUT/fat.img"
INTERP=/usr/lib/musl/lib/libc.so   # musl's dynamic linker == its libc
"$OUT/mkfat" "$OUT/fat.img" "${XENOS_AI_TOKEN:-}" "$INTERP"    # XENOS_AI_TOKEN (if set) is the live AI key; never committed
cp -f "$OUT/fat.img" "$OUT/sata.img"    # identical volume shown to the AHCI controller

echo "[build] kernel (C3, freestanding, elf-x64)"
# (the 8x8 font xk_font.c3 is committed; regenerate with tools/mkfont if redrawn)
echo "[build] assemble + embed ring-3 user program"
nasm -f bin -o "$OUT/user_prog.bin" "$ROOT/user/sys_prog.asm"
"$OUT/mkbin" "$OUT/user_prog.bin" "$SRC/xk_uprog.c3" user_prog
echo "[build] uhello static musl ELF (Linux test binary bundled into the kernel)"
if command -v musl-gcc >/dev/null 2>&1; then
    musl-gcc -static -no-pie -O2 -o "$OUT/uhello" "$ROOT/tools/u_shmfs.c"
    rm -f "$SRC/xk_ublob.c3"     # mkbin's lx_open creates mode-0000; truncate may then fail
    "$OUT/mkbin" "$OUT/uhello" "$SRC/xk_ublob.c3" linux_blob
    echo "    bundled uhello = $(stat -c%s "$OUT/uhello") bytes"
    echo "[build] uhello DYNAMIC musl ELF (dynamic main; interp loaded from FAT)"
    musl-gcc -no-pie -O2 -o "$OUT/uhello_dyn" "$ROOT/tools/u_shmfs.c"
    rm -f "$SRC/xk_dynblob.c3"
    "$OUT/mkbin" "$OUT/uhello_dyn" "$SRC/xk_dynblob.c3" dyn_blob
    echo "    dynamic main = $(stat -c%s "$OUT/uhello_dyn") bytes"
else
    echo "    [warn] musl-gcc not found; building placeholder blobs"
    printf '' > "$SRC/xk_ublob.c3"
    printf '' > "$SRC/xk_dynblob.c3"
fi
mkdir -p "$OUT/ccobl"
rm -f "$OUT"/ccobl/obj/elf-x64/*.o
( cd "$OUT/ccobl" && c3c compile-only --target elf-x64 --no-entry --use-stdlib=no --x86cpu=baseline --x86vec=none -O2 -g0 \
    "$SRC/xk_main.c3" "$SRC/xk_core.c3" "$SRC/xk_intr.c3" "$SRC/xk_kbd.c3" \
    "$SRC/xk_mouse.c3" "$SRC/xk_font.c3" "$SRC/xk_fb.c3" \
    "$SRC/xk_wm.c3" "$SRC/xk_apps.c3" "$SRC/xk_sched.c3" "$SRC/xk_shell.c3" "$SRC/xk_mem.c3" "$SRC/xk_sys.c3" "$SRC/xk_alloc.c3" "$SRC/xk_umode.c3" "$SRC/xk_uprog.c3" "$SRC/xk_linux.c3" "$SRC/xk_ublob.c3" "$SRC/xk_dynblob.c3" "$SRC/xk_pci.c3" "$SRC/xk_rtc.c3" "$SRC/xk_ata.c3" "$SRC/xk_fat.c3" "$SRC/xk_ext4.c3" "$SRC/xk_ahci.c3" "$SRC/xk_ai_cfg.c3" "$SRC/xk_ai_client.c3" "$SRC/xk_chat.c3" "$SRC/xk_net.c3" "$SRC/xk_ip.c3" "$SRC/xk_tcp.c3" "$SRC/xk_http.c3" "$SRC/xk_agent.c3" "$SRC/xk_sha256.c3" "$SRC/xk_tls.c3" "$SRC/xk_aes.c3" )
echo "[build] asm runtime"
nasm -f elf64 -o "$OUT/asm_runtime.o" "$SRC/asm_runtime.asm"

echo "[build] link kernel at 1 MiB (entry object first so xk_main is at 0x100000)"
OBJS=$(find "$OUT/ccobl/obj/elf-x64" -name '*.o' | grep 'xk_main\.o' || true)
REST=$(find "$OUT/ccobl/obj/elf-x64" -name '*.o' | grep -v 'xk_main\.o' || true)
ld -m elf_x86_64 -T "$KERNEL/linker.ld" -o "$OUT/kernel.elf" $OBJS $REST "$OUT/asm_runtime.o"
objcopy -O binary "$OUT/kernel.elf" "$OUT/kernel.bin"
echo "    kernel.bin = $(stat -c%s "$OUT/kernel.bin") bytes"

echo "[build] assemble disk image"
"$OUT/mkdisk" "$OUT/stage1.bin" "$OUT/stage2.bin" "$OUT/kernel.bin" "$OUT/xenos.img"
echo "    xenos.img = $(stat -c%s "$OUT/xenos.img") bytes"

if command -v xorrisofs >/dev/null 2>&1; then
    echo "[build] bootable ISO (El Torito no-emulation; hand-written loader + xorrisofs)"
    nasm -f bin -o "$OUT/iso_boot.bin" "$ROOT/iso/iso_boot.asm"
    mkdir -p "$OUT/isoroot"
    "$OUT/mkbootimg" "$OUT/iso_boot.bin" "$OUT/kernel.bin" "$OUT/isoroot/xenos_boot.img"
    xorrisofs -quiet -o "$OUT/xenos.iso" -b xenos_boot.img -no-emul-boot -boot-load-size 108 "$OUT/isoroot" 2>/dev/null
    echo "    xenos.iso = $(stat -c%s "$OUT/xenos.iso") bytes (qemu -cdrom / -boot d)"
else
    echo "[build] xorrisofs not found; skipping ISO (qemu -drive xenos.img works)"
fi

echo "[build] done"
echo "    disk:  qemu-system-x86_64 -drive file=build/xenos.img,format=raw -m 256 ..."
echo "    iso:   qemu-system-x86_64 -cdrom  build/xenos.iso -m 256 ..."