#!/usr/bin/env bash
# Shows that one WebSocket client that stops reading stalls an OpenTelemetry Collector's pipeline through the
# remotetap processor, and that the pipeline stays stuck after the client goes away.
# Needs: docker (or OTELCOL=/path/to/otelcol-contrib), python3, curl. Uses ports 4318 and 12001 on localhost.
set -u
cd "$(dirname "$0")"
VERSION=${VERSION:-0.162.0}
OUT=$(mktemp -d); chmod 777 "$OUT"

if [ -n "${OTELCOL:-}" ]; then
  sed "s#/tmp/out#$OUT#" collector.yaml > "$OUT/collector.yaml"
  "$OTELCOL" --config="$OUT/collector.yaml" > "$OUT/collector.log" 2>&1 & PID=$!
  stop() { kill $PID 2>/dev/null; }
  dump() { kill -QUIT $PID; sleep 2; cat "$OUT/collector.log"; }
else
  docker rm -f tapstall >/dev/null 2>&1
  docker run -d --name tapstall -p 4318:4318 -p 12001:12001 -v "$PWD/collector.yaml:/etc/otelcol-contrib/config.yaml:ro" \
    -v "$OUT:/tmp/out" "otel/opentelemetry-collector-contrib:$VERSION" >/dev/null || exit 1
  stop() { docker rm -f tapstall >/dev/null; }
  dump() { docker kill -s QUIT tapstall >/dev/null; sleep 2; docker logs tapstall 2>&1; }
fi
trap stop EXIT

record() { printf '{"resourceLogs":[{"resource":{"attributes":[]},"scopeLogs":[{"logRecords":[%s]}]}]}' \
  "$(for j in $(seq 1 300); do printf '{"body":{"stringValue":"request %s record %s %s"}},' "$1" "$j" "$(printf 'x%.0s' $(seq 1 150))"; done | sed 's/,$//')"; }
# Sends N requests; prints how many the collector accepted and how many got no answer within 5 s.
send() {
  local ok=0 timeout=0
  for i in $(seq 1 "$1"); do
    if record "$i" | curl -sf -o /dev/null --max-time 5 -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:4318/v1/logs; then ok=$((ok+1)); else timeout=$((timeout+1)); [ $timeout -ge 3 ] && break; fi
  done
  echo "  accepted: $ok, no answer in 5s: $timeout"
}
stored() { echo "  records written by the exporter: $(cat "$OUT"/records.jsonl 2>/dev/null | wc -l) batches"; }

printf 'Starting collector %s' "$VERSION"
for _ in $(seq 1 60); do curl -s -o /dev/null -X POST --max-time 1 -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:4318/v1/logs && break; printf .; sleep 1; done; echo

echo "1. No tap client: send 30 requests"; send 30; sleep 1; stored
echo "2. Connect one client that never reads"; python3 stuck_client.py 127.0.0.1 12001 40 & CLIENT=$!; sleep 1
echo "3. Send 300 more requests"; send 300; sleep 1; stored
echo "4. Wait 20 s with the client still connected, then try again"; sleep 20; send 3
echo "5. Let the client disconnect, wait 5 s, try again"; wait $CLIENT 2>/dev/null; sleep 5; send 3; stored
echo
echo "If steps 3 to 5 end with 'no answer in 5s', the pipeline is stalled and stays stalled after the client left."
echo "Goroutine dump, remotetap frames (count, where each goroutine waits):"
dump | grep -oE 'remotetapprocessor@[^ ]*/channelset\.go:[0-9]+' | sed 's#.*/##' | sort | uniq -c | sed \
  -e 's#channelset.go:36$#channelset.go:36  writeBytes waiting for the read lock (pipeline goroutines)#' \
  -e 's#channelset.go:38$#channelset.go:38  writeBytes holding the read lock, waiting to hand a client its message#' \
  -e 's#channelset.go:46$#channelset.go:46  closeAndRemove waiting for the write lock (the disconnected client)#'
