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

echo "[build] kernel (C3, freestanding, elf-x64)"
# (the 8x8 font xk_font.c3 is committed; regenerate with tools/mkfont if redrawn)
echo "[build] assemble + embed ring-3 user program"
nasm -f bin -o "$OUT/user_prog.bin" "$ROOT/user/sys_prog.asm"
"$OUT/mkbin" "$OUT/user_prog.bin" "$SRC/xk_uprog.c3"
mkdir -p "$OUT/ccobl"
rm -f "$OUT"/ccobl/obj/elf-x64/*.o
( cd "$OUT/ccobl" && c3c compile-only --target elf-x64 --no-entry --use-stdlib=no --x86cpu=baseline --x86vec=none -O2 -g0 \
    "$SRC/xk_main.c3" "$SRC/xk_core.c3" "$SRC/xk_intr.c3" "$SRC/xk_kbd.c3" \
    "$SRC/xk_mouse.c3" "$SRC/xk_font.c3" "$SRC/xk_fb.c3" \
    "$SRC/xk_wm.c3" "$SRC/xk_apps.c3" "$SRC/xk_sched.c3" "$SRC/xk_shell.c3" "$SRC/xk_mem.c3" "$SRC/xk_sys.c3" "$SRC/xk_alloc.c3" "$SRC/xk_umode.c3" "$SRC/xk_uprog.c3" "$SRC/xk_pci.c3" "$SRC/xk_rtc.c3" )
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
echo "[build] done -> $OUT/xenos.img"