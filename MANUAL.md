# Reproduce the remotetap stall by hand

You drive every step yourself, against a throwaway collector on your machine. **Don't do this against the cluster's
otel-gateway:** step 4 freezes its logs pipeline until the pod restarts.

You need Docker, curl, and [websocat](https://github.com/vi/websocat/releases) (`brew install websocat`, or the
release binary). Use three terminals, all from this folder.

## 1. Start the collector (terminal 1)

```bash
docker run --rm --name taplab -p 4318:4318 -p 12001:12001 -p 1777:1777 \
  -v "$PWD/compose/collector.yaml:/etc/otelcol-contrib/config.yaml:ro" otel/opentelemetry-collector-contrib:0.162.0
```

That gives OTLP/HTTP on :4318, the remote tap on :12001 and pprof on :1777. Stop it with Ctrl-C.

This terminal also shows what leaves the collector: the debug exporter logs one `info Logs {... "log records": 1}`
line per batch it exports. When the pipeline stalls, those lines stop. For each record's body, set
`verbosity: normal` in `compose/collector.yaml` (the bodies from `sendlogs.sh` are 200 KB, so the lines are long).

## 2. Watch the tap (terminal 2)

```bash
websocat -B 1000000 ws://localhost:12001
```

No websocat? Node 22 or later has a WebSocket client built in, and this does the same job (it prints the start of
each message). Ctrl-Z, `fg` and `kill -9 %1` work on it just the same:

```bash
node -e 'new WebSocket("ws://localhost:12001").onmessage = (e) => console.log(String(e.data).slice(0, 200))'
```

## 3. Send logs (terminal 3)

```bash
./sendlogs.sh 5
```

Each request prints `200`, and terminal 2 shows the OTLP JSON for each one (big, about 200 KB of x's). The tap works.

## 4. Pause the reader, then send more

In terminal 2 press **Ctrl-Z**, so websocat stops reading. Then in terminal 3:

```bash
./sendlogs.sh 400
```

After a few dozen requests one prints `000` (no answer in 5 s). The kernel buffers between the collector and
websocat are full, and the collector's pipeline is waiting on that one paused reader. Nothing gets through for any
sender now.

## 5a. Resume it: the pipeline recovers

In terminal 2 type `fg`, so websocat reads again. `./sendlogs.sh 3` prints `200` three times.

## 5b. Or kill it: the pipeline stays stuck

Do step 4 again, then in terminal 2 press **Ctrl-Z** and run `kill -9 %1` instead. Then:

```bash
./sendlogs.sh 3          # 000: still stuck, though no client is connected any more
curl -s 'localhost:1777/debug/pprof/goroutine?debug=2' | grep -oE 'channelset\.go:[0-9]+' | sort | uniq -c
```

The dump shows goroutines waiting at `channelset.go:36`, `:38` and `:46`, which is the deadlock. Only a restart
clears it: Ctrl-C in terminal 1 and start again.

Ctrl-S in a terminal (scroll lock), tmux copy mode, or `websocat ... | less` all do the same as Ctrl-Z. Closing the
laptop lid does too.
