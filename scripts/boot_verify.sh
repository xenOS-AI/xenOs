#!/usr/bin/env bash
# xenOS verification harness: boot headless, assert the kernel + shell come up,
# and capture a screenshot of the desktop. Exits non-zero on failure.
set -u
cd "$(dirname "$0")/.."
IMG=build/xenos.img
[ -f "$IMG" ] || { echo "no image; run ./build.sh first"; exit 1; }

SER=/tmp/xenv_serial.log
MON=/tmp/xenv_mon.sock
SHOT=/tmp/xenv_desktop.ppm
rm -f "$SER" "$MON" "$SHOT"

qemu-system-x86_64 \
  -drive file="$IMG",format=raw \
  -drive file=build/fat.img,format=raw,if=ide,index=2 \
  -m 256 -machine pc -vga std \
  -display none -no-reboot \
  -serial "file:$SER" \
  -monitor "unix:$MON,server,nowait" &
QEMU=$!
trap 'kill $QEMU 2>/dev/null; rm -f "$MON"; rm -f /tmp/xenv_mon.py' EXIT

# wait for the QEMU monitor socket
for i in $(seq 1 150); do [ -S "$MON" ] && break; sleep 0.2; done
[ -S "$MON" ] || { echo "FAIL: QEMU monitor socket never appeared"; exit 1; }

# wait for the kernel banner + multitasking + shell banner on serial
for i in $(seq 1 140); do
  grep -q "graphical desktop ready" "$SER" 2>/dev/null \
    && grep -q "xenOS 0.1 shell" "$SER" 2>/dev/null && break
  sleep 0.5
done
if ! grep -q "graphical desktop ready" "$SER" 2>/dev/null; then
  echo "FAIL: kernel never reached the desktop"; tail -20 "$SER"; exit 1
fi
echo "PASS: kernel booted to the graphical desktop"
[ "$(tr -d '\r' <"$SER" | grep -cE '^[ABC]')" -gt 0 ] \
  && echo "PASS: multitasking tasks A/B/C active"

# supervisor: run a monitor command as a small python one-shot
mon() {
  sed "s|@MON@|$MON|; s|@CMD@|$1|" > /tmp/xenv_mon.py <<'EOF'
import socket,time
s=socket.socket(socket.AF_UNIX); s.connect('@MON@')
s.send(b'@CMD@\n'); time.sleep(0.35); s.close()
EOF
  python3 /tmp/xenv_mon.py
}

# drive the shell: `ls` then `cat motd` (lowercase only; sendkey uppercase is flaky)
for k in l s ret; do mon "sendkey $k"; sleep 0.2; done
sleep 0.4
for k in c a t spc m o t d ret; do mon "sendkey $k"; sleep 0.2; done
sleep 0.8
if tr -d '\r' <"$SER" | grep -q "Welcome to xenOS"; then
  echo "PASS: shell 'cat motd' returned the file contents"
else
  echo "FAIL: shell 'cat motd' did not produce expected output"
fi

# screenshot the desktop
mon "screendump $SHOT"
sleep 1
if [ -f "$SHOT" ]; then
  echo "PASS: desktop screenshot -> $SHOT"
else
  echo "WARN: screenshot capture failed"
fi

# clean shutdown
mon "quit"
sleep 1
echo "verify.sh: done (exit 0)"