#!/usr/bin/env bash
# Enforce the Stremio streaming-server cache/buffer size (10 GiB) once the
# server is listening. Run as an ExecStartPost so it's applied on every start,
# self-healing on a fresh cache volume or a new machine. Idempotent; never
# fails the unit (streaming works without it, just with the 2 GiB default).
for _ in $(seq 1 30); do
  if /usr/bin/curl -sf -m 5 -X POST http://127.0.0.1:11470/settings \
      -H 'Content-Type: application/json' \
      -d '{"cacheSize":10737418240}' >/dev/null 2>&1; then
    exit 0
  fi
  sleep 2
done
exit 0
