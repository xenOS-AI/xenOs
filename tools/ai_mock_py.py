#!/usr/bin/env python3
"""Host-side diagnostic mock AI provider.
Listens on 127.0.0.1:9080 (slirp maps guest 10.0.2.2 -> host loopback).
Logs every byte received, replies with a canned chat/completions JSON.
"""
import socket, sys, time, threading

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9080
LOG = sys.argv[2] if len(sys.argv) > 2 else "/tmp/ai_mock_recv.txt"
BODY = (b'{"choices":[{"message":{"role":"assistant","content":"Hello from host mock '
        b'via QEMU networking! xenOS reached me over the bridge."}}]}')

def handle(c, addr):
    data = b""
    c.settimeout(3)
    try:
        while True:
            chunk = c.recv(8192)
            if not chunk: break
            data += chunk
            if b"\r\n\r\n" in data: break
    except socket.timeout:
        pass
    with open(LOG, "ab") as f:
        f.write(b"=== conn from %s ===\n" % str(addr).encode())
        f.write(data)
        f.write(b"\n=== end conn (%d bytes) ===\n" % len(data))
    l = len(BODY)
    hdr = (b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
           b"Content-Length: %d\r\nConnection: close\r\n\r\n" % l)
    c.sendall(hdr + BODY)
    c.close()
    with open(LOG, "ab") as f:
        f.write(b"=== replied (200, %d bytes) ===\n" % l)

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", PORT))
s.listen(4)
print("mock listening on 127.0.0.1:%d, logging to %s" % (PORT, LOG), flush=True)
while True:
    c, a = s.accept()
    threading.Thread(target=handle, args=(c, a), daemon=True).start()