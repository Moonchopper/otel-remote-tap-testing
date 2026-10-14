#!/usr/bin/env bash
# Sends N log requests (default 200) of about 200 KB each; stops at the first one that gets no answer in 5 s.
pad=$(head -c 200000 /dev/zero | tr '\0' x)
for i in $(seq 1 ${1:-200}); do
  code=$(printf '{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"body":{"stringValue":"hello %s %s"}}]}]}]}' $i "$pad" |
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Content-Type: application/json' --data-binary @- localhost:4318/v1/logs)
  echo "request $i: $code"; [ "$code" = 000 ] && break
done
