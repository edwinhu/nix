"""A stand-in for the Cast receiver: attach to the stream, read, then drop.

Attaching and dropping is the whole point — the bridge is supposed to notice the
drop and re-cast, and nothing about that needs a real speaker.
"""

import socket
import sys
import time

host, port, seconds = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
# Optional 4th arg: the source address to connect FROM. 127.0.0.0/8 is all
# local, so binding 127.0.0.2 lets one client look like the speaker and another
# like a stranger on the same loopback interface.
src = sys.argv[4] if len(sys.argv) > 4 else None

s = socket.socket()
if src:
    s.bind((src, 0))
s.settimeout(10)
s.connect((host, port))
s.sendall(b"GET /stream.mp3 HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n")
s.settimeout(2)

deadline = time.time() + seconds
total = 0
while time.time() < deadline:
    try:
        chunk = s.recv(8192)
    except TimeoutError:
        continue
    if not chunk:
        break
    total += len(chunk)

s.close()
print(f"read {total} bytes in {seconds}s")
