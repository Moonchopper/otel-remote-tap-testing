"""A remote-tap WebSocket client that connects, then never reads a byte.

Like a terminal paused with Ctrl-S, a laptop gone to sleep, or `websocat ... | less`.
"""
import base64, os, socket, sys, time

host, port, seconds = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)  # small buffer: the stall comes sooner
s.connect((host, port))
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
print("tap answered:", s.recv(64).split(b"\r\n")[0].decode(), flush=True)
time.sleep(seconds)  # never read again; exiting closes the socket
