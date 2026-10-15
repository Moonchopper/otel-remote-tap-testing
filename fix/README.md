# A fix for the remotetap stall

`remotetap-fix.patch` applies to the contrib repo at v0.162.0 (`patch -p1` from the repo root). It makes three changes
to `processor/remotetapprocessor`:

1. `channelset.go` `writeBytes`: send to each client with `select` and a `default`, so a client that is behind has its
   copy dropped instead of holding up the pipeline and the read lock.
2. `processor.go` `handleConn`: give each client a channel buffered for 16 messages, so a healthy reader loses nothing
   to ordinary jitter.
3. `processor.go` `handleConn`: set a 10 s write deadline before each `conn.Write`, so a reader that stops reading is
   removed instead of holding its goroutine forever.

It also adds `TestChannelSetStuckClient` (fails on v0.162.0, passes with the fix), and gives the existing rate-limit
tests buffered channels, since they now measure the limiter rather than a blocking hand-off.

## Try it

```bash
./build.sh   # Go 1.26+ and Docker: patches, runs the package tests, builds a small collector image
cd ../compose
VERSION=0.162.0-tapfix docker compose up --abort-on-container-exit --exit-code-from driver; docker compose down
```

Expected: every step accepted (`300`, `3`, `3`) and `none: the tap isn't stuck` in the goroutine dump.
For the manual steps in `MANUAL.md`, use the image `otel/opentelemetry-collector-contrib:0.162.0-tapfix` and add
`--config=/etc/otelcol-contrib/config.yaml` after it.
