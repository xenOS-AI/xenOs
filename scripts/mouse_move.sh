import socket, struct, time

def connect(port=5900):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.settimeout(3)
    s.recv(12); s.sendall(b"RFB 003.008\n")
    n = s.recv(1)[0]
    seclist = b""
    while len(seclist) < n: seclist += s.recv(n - len(seclist))
    pick = 1 if 1 in seclist else seclist[0]
    s.sendall(bytes([pick])); s.recv(4)
    s.sendall(b"\x00"); time.sleep(0.3)
    s.settimeout(0)
    try:
        while s.recv(4096): pass
    except Exception: pass
    s.settimeout(3)
    return s

def ptr(s, x, y, m=0): s.sendall(b"\x05"+struct.pack("!BHH", m, x, y))

s = connect(5900)
time.sleep(0.8)
for _ in range(4): ptr(s, 700, 420); time.sleep(0.15)   # settle baseline
x, y = 700, 420
for i in range(14): x += 12; ptr(s, x, y); time.sleep(0.05)  # right sweep
for i in range(9): y += 9; ptr(s, x, y); time.sleep(0.05)    # down dip
time.sleep(1.2); s.close()
print("moved mouse: start(700,420) end(%d,%d)" % (x, y))