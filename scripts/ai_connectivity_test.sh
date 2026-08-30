#!/usr/bin/env bash
# Drive xenOS headless: boot, then type "aichat hello<ret>" in the shell.
set -uo pipefail
cd "$(dirname "$0")/.."
IMG=build/xenos.img

SER=/tmp/xenv_ai_serial.log
MON=/tmp/xenv_ai_mon.sock
rm -f "$SER" "$MON" /tmp/ai_mock_recv.txt

qemu-system-x86_64 \
  -drive file="$IMG",format=raw \
  -drive file=build/fat.img,format=raw,if=ide,index=2 \
  -device ich9-ahci,id=ahci -drive file=build/sata.img,format=raw,if=none,id=sd0 -device ide-hd,drive=sd0,bus=ahci.0 \
  -netdev user,id=net0,hostfwd=tcp::19080-10.0.2.15:9080 -device e1000,netdev=net0,mac=52:54:00:12:34:56 \
  -m 256 -machine pc -vga std -no-reboot \
  -display none -serial "file:$SER" \
  -monitor "unix:$MON,server,nowait" &
QEMU=$!
trap 'kill $QEMU 2>/dev/null' EXIT

for i in $(seq 1 150); do [ -S "$MON" ] && break; sleep 0.2; done

# wait for desktop + shell
for i in $(seq 1 160); do
  grep -q "grutt" "$SER" 2>/dev/null; true
  grep -q "xenOS 0.1 shell" "$SER" 2>/dev/null && break
  sleep 0.5
done
echo "shell banner reached"

mon() { python3 -c "import socket,time,sys;s=socket.socket(socket.AF_UNIX);s.connect('$MON');s.send(b'$1\\n');time.sleep(0.35);s.close()"; }

# focus on the terminal window? sendkey goes to the focused window; the shell
# window should be focused by default. Type: aichat hello
for k in a i c h a t spc h e l l o ret; do mon "sendkey $k"; sleep 0.12; done
sleep 8   # give TCP connect + ARP + HTTP + mock time (TCG is slow)

echo "=== serial tail ==="
tail -40 "$SER"
echo "=== mock received ==="
cat /tmp/ai_mock_recv.txt 2>/dev/null || echo "(mock got nothing)"
mon "quit"
sleep 1