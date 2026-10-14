# otel-remote-tap-testing: remotetap stall repro

Shows that one WebSocket client that stops reading stalls an OpenTelemetry Collector pipeline that has the contrib
`remotetap` processor in it, and that the pipeline stays stalled after that client disconnects.

With Docker Compose (nothing to install, no host ports used):

```bash
cd compose
docker compose up --abort-on-container-exit --exit-code-from driver; docker compose down
VERSION=0.150.0 docker compose up --abort-on-container-exit --exit-code-from driver; docker compose down
```

Always run `down` between runs: a stalled collector stays stalled. Inside the compose network step 3 stalls after a
couple of requests rather than ~47 (smaller socket buffers); the rest of the output matches.

By hand, one step at a time: see [MANUAL.md](MANUAL.md).

Or with the script:

```bash
./run.sh                                  # docker, otel/opentelemetry-collector-contrib:0.162.0
VERSION=0.150.0 ./run.sh                  # another release
OTELCOL=/path/to/otelcol-contrib ./run.sh # a local binary instead of docker
```

Needs python3, curl, and docker or a collector binary. Uses ports 4318 and 12001 on localhost and runs its own
throwaway collector (`collector.yaml`). Point it at nothing real.

Expected output (contrib 0.162.0):

```
1. No tap client: send 30 requests
  accepted: 30, no answer in 5s: 0
2. Connect one client that never reads
3. Send 300 more requests
  accepted: 47, no answer in 5s: 3       <- the pipeline stops once the client's socket buffers fill
4. Wait 20 s with the client still connected, then try again
  accepted: 0, no answer in 5s: 3
5. Let the client disconnect, wait 5 s, try again
  accepted: 0, no answer in 5s: 3        <- still stuck: deadlocked until the collector restarts
Goroutine dump, remotetap frames:
      7 channelset.go:36  writeBytes waiting for the read lock (pipeline goroutines)
      2 channelset.go:38  writeBytes holding the read lock, waiting to hand a client its message
      1 channelset.go:46  closeAndRemove waiting for the write lock (the disconnected client)
```

Why: `channelSet.writeBytes` sends each message to every client over an unbuffered channel while holding a read lock,
so it waits for each client's `conn.Write`. When the stalled client's write finally fails, its handler calls
`closeAndRemove`, which needs the write lock that the waiting `writeBytes` calls hold. Nothing reads that client's
channel any more, so neither side can move.
