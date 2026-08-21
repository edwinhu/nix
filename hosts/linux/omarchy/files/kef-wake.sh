#!/usr/bin/env bash
# Wake the KEF when something actually starts playing to it, and re-establish
# owntone's AirPlay session.
#
# The speaker's standby timer counts SILENCE, not absence of a stream, and its
# API refuses writes to settings:/kef/host/standbyMode ("Forbidden") — it can
# only be changed in the KEF Connect app. So the permanently-open AirPlay
# session does not keep it awake: after ~30 minutes of quiet it sleeps, and the
# next track plays into a sleeping speaker.
#
# Rather than defeat standby with inaudible noise (which would keep it powered
# 24/7), this wakes it on demand: a real, uncorked stream on the `kef` sink is
# the signal that someone wants audio now. The feeder does not count - it reads
# the MONITOR, so it is never a sink-input.
set -uo pipefail

COOLDOWN=30   # seconds; a wake takes a few seconds to settle, do not spam it
last_wake=0

kef_sink_id() { pactl list sinks short 2>/dev/null | awk '$2=="kef"{print $1; exit}'; }

# An uncorked sink-input on the kef sink. Parsed in python rather than awk on
# record separators: `pactl list sink-inputs` does not reliably end with a blank
# line, so the last (often only) entry was being dropped.
playing_to_kef() {
  local id; id="$(kef_sink_id)"
  [ -n "$id" ] || return 1
  pactl list sink-inputs 2>/dev/null | python3 -c '
import sys
want = sys.argv[1]
sink = corked = None
hit = False
for line in sys.stdin:
    t = line.strip()
    if t.startswith("Sink Input #"):
        sink = corked = None
    elif t.startswith("Sink:"):
        sink = t.split(":", 1)[1].strip()
    elif t.startswith("Corked:"):
        corked = t.split(":", 1)[1].strip()
    if sink == want and corked == "no":
        hit = True
        break
sys.exit(0 if hit else 1)
' "$id"
}

while true; do
  if playing_to_kef; then
    now=$SECONDS
    if [ $((now - last_wake)) -ge "$COOLDOWN" ]; then
      standby="$(timeout 10 kefctl panel 2>/dev/null | \
        python3 -c 'import json,sys; print(json.load(sys.stdin)["standby"])' 2>/dev/null)"
      if [ "$standby" = "True" ]; then
        echo "audio on kef sink and speaker is in standby - waking"
        timeout 10 kefctl toggle >/dev/null 2>&1
        sleep 6
        # The AirPlay session does not survive standby; re-select the output so
        # owntone rebuilds it rather than streaming into a dead session.
        id=$(curl -s -m 5 http://127.0.0.1:3689/api/outputs 2>/dev/null | \
          python3 -c 'import json,sys
for o in json.load(sys.stdin)["outputs"]:
    if "LSX" in o["name"] and o["type"].startswith("AirPlay"):
        print(o["id"]); break' 2>/dev/null)
        if [ -n "${id:-}" ]; then
          curl -s -m 5 -X PUT "http://127.0.0.1:3689/api/outputs/$id" -d '{"selected": true}' >/dev/null
          echo "re-selected owntone output $id"
        fi
        last_wake=$SECONDS
      fi
    fi
  fi
  sleep 3
done
