# otel-remote-tap-testing: remotetap stall repro

Shows that one WebSocket client that stops reading stalls an OpenTelemetry Collector pipeline that has the contrib
`remotetap` processor in it, and that the pipeline stays stalled after that client disconnects.

With Docker Compose (nothing to install, no host ports used):

```bash
cd compose
docker compose up --abort-on-container-exit --exit-code-from driver; docker compose down
VERSION=0.150.0 docker compose up --abort-on-container-exit --exit-code-from driver; docker compose down
```

To watch batches leave the collector through its debug exporter, run `docker compose logs -f collector` in another
terminal. Always run `down` between runs: a stalled collector stays stalled. Inside the compose network step 3 stalls after a
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

## Where it happens in the code

The contrib `remotetap` processor, v0.162.0 (unchanged on `main` as of October 2026). A goroutine dump of a stuck
collector parks on exactly these lines.

1. **Every batch waits for the tap.** `ConsumeLogs` doesn't return until `writeBytes` has handed the batch to every
   client, so the receiver that sent it waits too.
   [processor.go#L117-L127](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.162.0/processor/remotetapprocessor/processor.go#L117-L127)
2. **Each client gets an unbuffered channel and no write deadline.** `handleConn` clears the deadline (line 70), makes
   `ch := make(chan []byte)` (line 75), and loops on `conn.Write` (line 78), which blocks once the client's TCP buffers
   are full.
   [processor.go#L69-L84](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.162.0/processor/remotetapprocessor/processor.go#L69-L84)
3. **A reader stops: the pipeline stalls.** `writeBytes` takes the read lock (line 36) and sends to each client's
   channel in turn (line 38). The stuck client's goroutine never takes the message, so every batch waits at line 38.
   It recovers if the reader starts reading again.
   [channelset.go#L35-L41](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.162.0/processor/remotetapprocessor/channelset.go#L35-L41)
4. **The reader disconnects: the tap deadlocks.** `conn.Write` fails and the handler calls `closeAndRemove`, which
   needs the write lock (line 46). That waits for the read locks held at line 38, which wait for a channel only this
   handler would read. Go's `RWMutex` blocks new readers once a writer waits, so later batches park at line 36. Only a
   restart clears it.
   [channelset.go#L45-L50](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.162.0/processor/remotetapprocessor/channelset.go#L45-L50)

## The fix

[`fix/`](fix/) has a patch against v0.162.0 and a script that builds a collector with it. Three changes:

- **`writeBytes` sends without waiting** (`select` with a `default` that drops). The pipeline never waits on a reader,
  and the read lock is only held for a loop that can't block, so `closeAndRemove` always gets the write lock. That
  removes both the stall and the deadlock.
- **Each client's channel holds 16 messages**, so a healthy reader doesn't lose messages to ordinary jitter.
- **Each write has a 10 s deadline**, so a reader that stops reading is removed instead of holding its goroutine
  forever.

The cost: a reader more than 16 messages behind misses messages, which is fine for a rate-limited sample. Against the
same repro the patched collector accepted 300 of 300 requests with the stuck reader connected, and 3 of 3 after it
left, with nothing parked in `remotetap`.

## The pattern, interactively

[`docs/index.html`](docs/index.html) is an interactive diagram of a gateway with a tap and a relay in front of it. Toggle
between readers on the tap directly and readers through the relay, and stall one reader to see what happens. It ends
with the walkthrough above. Open it in a browser, or serve the repo with GitHub Pages from `/docs`.
