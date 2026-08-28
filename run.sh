#!/usr/bin/env bash
# xenOS boot script: boots the hand-written OS in QEMU.
#   ./run.sh            - graphical window (needs a display; default)
#   ./run.sh serial     - headless, serial console on stdout (for CI/scripts)
set -euo pipefail
cd "$(dirname "$0")"

IMG=build/xenos.img
[[ -f "$IMG" ]] || { echo "build/xenos.img missing - run ./build.sh first"; exit 1; }

BASE=(-drive file="$IMG",format=raw -drive file=build/fat.img,format=raw,if=ide,index=2 -device ich9-ahci,id=ahci -drive file=build/sata.img,format=raw,if=none,id=sd0 -device ide-hd,drive=sd0,bus=ahci.0 -m 256 -machine pc -vga std -no-reboot \
  -netdev user,id=net0,hostfwd=tcp::19080-10.0.2.15:9080 -device e1000,netdev=net0,mac=52:54:00:12:34:56)

if [[ "${1:-}" == "serial" ]]; then
    qemu-system-x86_64 "${BASE[@]}" -display none -serial stdio
else
    qemu-system-x86_64 "${BASE[@]}" -serial file:/tmp/xenos-serial.log -display gtk
fi