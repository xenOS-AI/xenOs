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

echo "[build] kernel (C3, freestanding, elf-x64)"
echo "[build] generate 8x8 font"
python3 "$ROOT/tools/mkfont.py" "$SRC/xk_font.c3" >/dev/null
mkdir -p "$OUT/ccobl"
rm -f "$OUT"/ccobl/obj/elf-x64/*.o
( cd "$OUT/ccobl" && c3c compile-only --target elf-x64 --no-entry --use-stdlib=no --x86cpu=baseline --x86vec=none -O2 -g0 \
    "$SRC/xk_main.c3" "$SRC/xk_core.c3" "$SRC/xk_intr.c3" "$SRC/xk_kbd.c3" \
    "$SRC/xk_mouse.c3" "$SRC/xk_font.c3" "$SRC/xk_fb.c3" \
    "$SRC/xk_wm.c3" "$SRC/xk_apps.c3" "$SRC/xk_sched.c3" "$SRC/xk_shell.c3" "$SRC/xk_mem.c3" )
echo "[build] asm runtime"
nasm -f elf64 -o "$OUT/asm_runtime.o" "$SRC/asm_runtime.asm"

echo "[build] link kernel at 1 MiB (entry object first so xk_main is at 0x100000)"
OBJS=$(find "$OUT/ccobl/obj/elf-x64" -name '*.o' | grep 'xk_main\.o' || true)
REST=$(find "$OUT/ccobl/obj/elf-x64" -name '*.o' | grep -v 'xk_main\.o' || true)
ld -m elf_x86_64 -T "$KERNEL/linker.ld" -o "$OUT/kernel.elf" $OBJS $REST "$OUT/asm_runtime.o"
objcopy -O binary "$OUT/kernel.elf" "$OUT/kernel.bin"
echo "    kernel.bin = $(stat -c%s "$OUT/kernel.bin") bytes"

echo "[build] assemble disk image"
python3 "$ROOT/tools/mkdisk.py" "$OUT/stage1.bin" "$OUT/stage2.bin" "$OUT/kernel.bin" "$OUT/xenos.img"
echo "    xenos.img = $(stat -c%s "$OUT/xenos.img") bytes"
echo "[build] done -> $OUT/xenos.img"