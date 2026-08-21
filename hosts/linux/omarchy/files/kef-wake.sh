#!/usr/bin/env bash
# Keep the KEF actually playing what is sent to it.
#
# Two failure modes, one trigger. The speaker's standby timer counts SILENCE,
# not absence of a stream (and standbyMode is not writable over its API -
# "Forbidden" - it is a KEF Connect app setting), so after ~30min of quiet it
# sleeps. Waking it kills the AirPlay session, and owntone does NOT notice: it
# keeps its UDP socket open and keeps reporting `play` while the speaker's own
# player sits at "stopped". Local state is green end to end and no audio comes
# out.
#
# So do not infer from local state. Ask the speaker: player:player/data is
# authoritative about whether audio is landing. If something is playing to the
# `kef` sink and the speaker is not playing it, wake it if asleep and make
# owntone rebuild the session by re-selecting the output.
#
# The feeder never counts as playback - it reads the MONITOR, so it is not a
# sink-input.
set -uo pipefail

# mDNS name, not an IP: the speaker is on DHCP and has moved before
# (.190 -> .207), which is what broke every hardcoded address here.
SPEAKER=lsxlite-84171507148c.local
COOLDOWN=30   # seconds; a rebuild takes a few seconds to settle, do not spam it
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

speaker_state() {
  timeout 8 curl -s -m 5 -G "http://$SPEAKER/api/getData" \
    --data-urlencode "path=player:player/data" --data-urlencode "roles=value" 2>/dev/null |
    python3 -c 'import json,sys
try: print(json.load(sys.stdin)[0].get("state",""))
except Exception: print("")' 2>/dev/null
}

airplay_output_id() {
  curl -s -m 5 http://127.0.0.1:3689/api/outputs 2>/dev/null | python3 -c 'import json,sys
try:
    for o in json.load(sys.stdin)["outputs"]:
        if "LSX" in o["name"] and o["type"].startswith("AirPlay"):
            print(o["id"]); break
except Exception: pass' 2>/dev/null
}

while true; do
  if playing_to_kef; then
    now=$SECONDS
    if [ $((now - last_wake)) -ge "$COOLDOWN" ]; then
      state="$(speaker_state)"
      # "" means the speaker did not answer - do not thrash the session on a
      # transient network hiccup, just try again next tick.
      if [ -n "$state" ] && [ "$state" != "playing" ]; then
        echo "audio on kef sink but speaker reports '$state' - recovering"
        if [ "$state" = "standby" ] || \
           [ "$(timeout 10 kefctl panel 2>/dev/null |
                python3 -c 'import json,sys; print(json.load(sys.stdin)["standby"])' 2>/dev/null)" = "True" ]; then
          timeout 10 kefctl toggle >/dev/null 2>&1
          sleep 6
        fi
        id="$(airplay_output_id)"
        if [ -n "$id" ]; then
          # Deselect first: re-selecting an already-selected output is a no-op,
          # and the stale session is exactly what has to be torn down.
          curl -s -m 5 -X PUT "http://127.0.0.1:3689/api/outputs/$id" -d '{"selected": false}' >/dev/null
          sleep 2
          curl -s -m 5 -X PUT "http://127.0.0.1:3689/api/outputs/$id" -d '{"selected": true}' >/dev/null
          echo "rebuilt owntone session on output $id"
        fi
        last_wake=$SECONDS
      fi
    fi
  fi
  sleep 3
done
