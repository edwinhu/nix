#!/usr/bin/env bash
# Enforce Stremio streaming-server tuning once the server is listening:
#  - cacheSize 10 GiB (default 2 GiB) so streams buffer far enough ahead.
#  - proxyStreamsEnabled: route HTTP streams through the server so they actually
#    hit the cache/buffer (otherwise direct-HTTP sources bypass it and stall).
# Run as an ExecStartPost so it's applied on every start, self-healing on a fresh
# cache volume / new machine. Idempotent; never fails the unit.
for _ in $(seq 1 30); do
  if /usr/bin/curl -sf -m 5 -X POST http://127.0.0.1:11470/settings \
      -H 'Content-Type: application/json' \
      -d '{"cacheSize":10737418240,"proxyStreamsEnabled":true,"btDownloadSpeedSoftLimit":73400320,"btDownloadSpeedHardLimit":104857600,"btMaxConnections":200}' >/dev/null 2>&1; then
    exit 0
  fi
  sleep 2
done
exit 0
