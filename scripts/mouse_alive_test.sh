#!/usr/bin/env bash
# Verify the mouse cursor renders, stays alive over time, and tracks a moved
# target. Boots headless + VNC, screenshots at t0 and after waiting, then
# injects a gentle RFB move and screenshots again, checking the cursor moves.
set -u
cd /home/timo/Documents/xenOS
IMG=build/xenos.img; SER=/tmp/xm_serial.log; MON=/tmp/xm_mon.sock
rm -f "$SER" "$MON" /tmp/x0.ppm /tmp/x1.ppm /tmp/x2.ppm
qemu-system-x86_64 -drive file="$IMG",format=raw \
  -drive file=build/fat.img,format=raw,if=ide,index=2 \
  -device ich9-ahci,id=ahci -drive file=build/sata.img,format=raw,if=none,id=sd0 -device ide-hd,drive=sd0,bus=ahci.0 \
  -netdev user,id=net0,hostfwd=tcp::19080-10.0.2.15:9080 -device e1000,netdev=net0,mac=52:54:00:12:34:56 \
  -m 256 -machine pc -vga std -vnc 127.0.0.1:0 -no-reboot \
  -serial "file:$SER" -monitor "unix:$MON,server,nowait" &
QEMU=$!
trap 'kill $QEMU 2>/dev/null; rm -f "$MON" /tmp/xm_mon.py' EXIT
for i in $(seq 1 150); do [ -S "$MON" ] && break; sleep 0.2; done
mon(){ sed "s|@MON@|$MON|; s|@CMD@|$1|" >/tmp/xm_mon.py <<'EOF'
import socket,time
s=socket.socket(socket.AF_UNIX); s.connect('@MON@'); s.send(b'@CMD@\n'); time.sleep(0.5); s.close()
EOF
python3 /tmp/xm_mon.py; }
for i in $(seq 1 240); do grep -q "graphical desktop ready" "$SER" 2>/dev/null && break; sleep 0.5; done
sleep 5
echo "about to boot desktop + t0"; mon "screendump /tmp/x0.ppm"; sleep 1
echo "waiting 18s (cursor must stay alive despite demo tasks)..."; sleep 18
mon "screendump /tmp/x1.ppm"; sleep 1
echo "move mouse (RFB)"; python3 scripts/mouse_move.sh
sleep 1
mon "screendump /tmp/x2.ppm"; sleep 1
mon "quit"; sleep 1
echo done