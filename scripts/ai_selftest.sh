#!/usr/bin/env bash
# Headless boot, capture serial; no GUI typing needed.
set -uo pipefail
cd "$(dirname "$0")/.."
IMG=build/xenos.img
SER=/tmp/xenv_st_serial.log
rm -f "$SER"
qemu-system-x86_64 \
  -drive file="$IMG",format=raw \
  -drive file=build/fat.img,format=raw,if=ide,index=2 \
  -device ich9-ahci,id=ahci -drive file=build/sata.img,format=raw,if=none,id=sd0 -device ide-hd,drive=sd0,bus=ahci.0 \
  -netdev user,id=net0 -device e1000,netdev=net0,mac=52:54:00:12:34:56 \
  -m 256 -machine pc -vga std -no-reboot \
  -display none -serial "file:$SER" &
QPID=$!
for i in $(seq 1 220); do
  grep -q "graphical desktop ready" "$SER" 2>/dev/null && break
  sleep 0.5
done
sleep 3
kill $QPID 2>/dev/null
wait 2>/dev/null
echo "=== selftest + net lines ==="
grep -aE "\[net\]|ARP|e1000|gateway" "$SER" | head -20