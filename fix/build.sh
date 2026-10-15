#!/usr/bin/env bash
# Builds a small collector (OTLP receiver, remotetap, debug and nop exporters, health_check, pprof) with
# remotetap-fix.patch applied, as the image otel/opentelemetry-collector-contrib:0.162.0-tapfix, so the repro
# can run against it: VERSION=0.162.0-tapfix docker compose up ... (in ../compose).
# Needs Go 1.26 or later and Docker.
set -euo pipefail
cd "$(dirname "$0")"
V=0.162.0
WORK=$(mktemp -d)
GOFLAGS=-mod=mod go mod download github.com/open-telemetry/opentelemetry-collector-contrib/processor/remotetapprocessor@v$V
SRC=$(go env GOMODCACHE)/github.com/open-telemetry/opentelemetry-collector-contrib/processor/remotetapprocessor@v$V
mkdir -p "$WORK/processor" && cp -r "$SRC" "$WORK/processor/remotetapprocessor" && chmod -R u+w "$WORK"
(cd "$WORK" && patch -p1 < "$OLDPWD/remotetap-fix.patch")
cd "$WORK/processor/remotetapprocessor"
# The module's go.mod points at sibling directories of the contrib monorepo; use the published modules instead.
for r in $(go mod edit -json | python3 -c 'import json,sys; [print(x["Old"]["Path"]) for x in json.load(sys.stdin).get("Replace") or [] if x["New"]["Path"].startswith("..")]'); do
  go mod edit -dropreplace="$r"
done
GOFLAGS=-mod=mod go mod tidy
GOFLAGS=-mod=mod go test -race ./...
cd "$OLDPWD"
go install go.opentelemetry.io/collector/cmd/builder@v$V
sed -e "s#@WORK@#$WORK#g" -e "s#@V@#v$V#g" builder.yaml > "$WORK/builder.yaml"
CGO_ENABLED=0 "$(go env GOPATH)/bin/builder" --config "$WORK/builder.yaml"
cp Dockerfile "$WORK/build/"
docker build -t otel/opentelemetry-collector-contrib:$V-tapfix "$WORK/build"
echo "Built otel/opentelemetry-collector-contrib:$V-tapfix"
