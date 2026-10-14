"""Stalls the collector's pipeline with one remote-tap client that never reads, then shows it stays stalled.

Same steps as ../run.sh, from inside the compose network. Standard library only.
"""
import base64, os, re, socket, threading, time, urllib.request
from collections import Counter

HOST = os.environ.get("COLLECTOR", "collector")
OTLP = f"http://{HOST}:4318/v1/logs"


def batch(n):
    pad = "x" * 150
    recs = ",".join(f'{{"body":{{"stringValue":"request {n} record {j} {pad}"}}}}' for j in range(300))
    return f'{{"resourceLogs":[{{"resource":{{"attributes":[]}},"scopeLogs":[{{"logRecords":[{recs}]}}]}}]}}'.encode()


def post(n):
    req = urllib.request.Request(OTLP, data=batch(n), headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=5).read()
        return True
    except Exception:
        return False


def send(count):
    """Sends up to `count` requests; stops after 3 that get no answer within 5 s."""
    ok = timeouts = 0
    for i in range(count):
        if post(i):
            ok += 1
        else:
            timeouts += 1
            if timeouts >= 3:
                break
    print(f"  accepted: {ok}, no answer in 5s: {timeouts}")


def stuck_client(seconds):
    """A WebSocket client that connects to the tap and never reads a byte (a paused terminal, a sleeping laptop)."""
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)  # small buffer: the stall comes sooner
    s.connect((HOST, 12001))
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET / HTTP/1.1\r\nHost: {HOST}:12001\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    print("  tap answered:", s.recv(64).split(b"\r\n")[0].decode())
    time.sleep(seconds)
    s.close()


WHERE = {
    "36": "writeBytes waiting for the read lock (pipeline goroutines)",
    "38": "writeBytes holding the read lock, waiting to hand a client its message",
    "46": "closeAndRemove waiting for the write lock (the disconnected client)",
}


def goroutines():
    dump = urllib.request.urlopen(f"http://{HOST}:1777/debug/pprof/goroutine?debug=2", timeout=10).read().decode()
    lines = Counter(re.findall(r"remotetapprocessor@[^\s]*/channelset\.go:(\d+)", dump))
    for line, n in sorted(lines.items(), key=lambda kv: int(kv[0])):
        print(f"  {n:3} channelset.go:{line:3} {WHERE.get(line, '')}")
    if not lines:
        print("  none: the tap isn't stuck")


print("Waiting for the collector", end="", flush=True)
for _ in range(60):
    try:
        urllib.request.urlopen(f"http://{HOST}:13133/", timeout=1)
        break
    except Exception:
        print(".", end="", flush=True)
        time.sleep(1)
print()

print("1. No tap client: send 30 requests"); send(30)
print("2. Connect one client that never reads")
client = threading.Thread(target=stuck_client, args=(40,)); client.start(); time.sleep(1)
print("3. Send 300 more requests"); send(300)
print("4. Wait 20 s with the client still connected, then try again"); time.sleep(20); send(3)
print("5. Let the client disconnect, wait 5 s, try again"); client.join(); time.sleep(5); send(3)
print()
print("If steps 3 to 5 end with 'no answer in 5s', the pipeline is stalled and stays stalled after the client left.")
print("Goroutine dump, remotetap frames (count, where each goroutine waits):")
goroutines()
