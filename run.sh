#!/usr/bin/env bash
# xenOS boot script: boots the hand-written OS in QEMU.
#   ./run.sh            - graphical window (needs a display; default)
#   ./run.sh serial     - headless, serial console on stdout (for CI/scripts)
set -euo pipefail
cd "$(dirname "$0")"

IMG=build/xenos.img
[[ -f "$IMG" ]] || { echo "build/xenos.img missing - run ./build.sh first"; exit 1; }

BASE=(-drive file="$IMG",format=raw -m 256 -machine pc -vga std -no-reboot)

if [[ "${1:-}" == "serial" ]]; then
    qemu-system-x86_64 "${BASE[@]}" -display none -serial stdio
else
    qemu-system-x86_64 "${BASE[@]}" -serial file:/tmp/xenos-serial.log -display gtk
fi