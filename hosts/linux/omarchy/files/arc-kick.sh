#!/usr/bin/env bash
# arc-kick — diagnose and repair the Sonos Beam's eARC link, on demand.
#
# Run it when the Beam is silent. It never polls and keeps no state: every fact
# it reports is read live, from the device that owns it.
#
# The chain is PC --DisplayPort--> BenQ EX321UX --eARC(HDMI 3)--> Beam Gen 2.
# Two independent things break it, and they need different fixes:
#   1. eARC negotiation drops. Only the MONITOR can re-initiate it (DisplayPort
#      carries no CEC, so the CEC bus is just monitor + Beam), which is why
#      power-cycling the Beam never helps. No software lever exists — measured:
#      DDC exposes no power (D6) or eARC control, VCP 8D is unimplemented, and a
#      VCP 60 input bounce leaves eARC untouched.
#   2. The Beam's AirPlay sink disappears from PipeWire after a replug.
#      raop-discover only creates sinks on an mDNS ADD and the Beam never stops
#      advertising, so it cannot return on its own. pipewire must restart —
#      wireplumber alone is NOT enough.
set -uo pipefail

BEAM_IP="${ARC_KICK_BEAM_IP:-192.168.4.206}"
BEAM_RINCON="${ARC_KICK_BEAM_RINCON:-RINCON_804AF2484A2E01400}"
HTASTREAM="x-sonos-htastream:$BEAM_RINCON:spdif"
FIX=1; [ "${1:-}" = "--check" ] && FIX=0

note() { printf '%s\n' "$*"; }
notify() { command -v notify-send >/dev/null && notify-send -a arc-kick "$1" "$2" || true; }

# One SOAP call to the Beam's AVTransport. $1 = action.
soap() {
  curl -s --max-time 8 "http://$BEAM_IP:1400/MediaRenderer/AVTransport/Control" \
    -H "SOAPACTION: \"urn:schemas-upnp-org:service:AVTransport:1#$1\"" \
    -H 'Content-Type: text/xml; charset="utf-8"' \
    -d "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:$1 xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><InstanceID>0</InstanceID>${2:-}</u:$1></s:Body></s:Envelope>"
}

# The whole diagnosis in one field: the TV input's URI, or empty when eARC is down.
arc_uri() { soap GetMediaInfo | grep -oE '<CurrentURI>[^<]*' | sed 's/<CurrentURI>//'; }

note "== PC end =="
# hw_ptr advancing is the only proof samples are really clocking out; a sink that
# merely says RUNNING can still be feeding a dead device.
hwp=$(grep -h . /proc/asound/card*/pcm*p/sub0/hw_params 2>/dev/null | grep -c rate)
if [ "$hwp" -gt 0 ]; then
  note "  HDMI stream open ($(grep -h '^rate' /proc/asound/card*/pcm*p/sub0/hw_params 2>/dev/null | head -1))"
else
  note "  no HDMI stream open right now (normal if nothing is playing)"
fi
sink=$(pactl list sinks short 2>/dev/null | grep hdmi-stereo | awk '{print $2"  "$NF}')
note "  sink: ${sink:-MISSING}"
if pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | grep -q yes; then
  note "  default sink is MUTED"
  [ "$FIX" = 1 ] && { pactl set-sink-mute @DEFAULT_SINK@ 0; note "  -> unmuted"; }
fi

note "== Beam =="
if ! curl -s --max-time 5 -o /dev/null "http://$BEAM_IP:1400/status"; then
  note "  UNREACHABLE at $BEAM_IP — check the network, or the IP moved (DHCP)."
  notify "arc-kick" "Beam unreachable at $BEAM_IP"
  exit 2
fi
uri=$(arc_uri)

if [ "$uri" = "$HTASTREAM" ]; then
  note "  eARC UP (TV input active)"
else
  note "  eARC DOWN (no TV input)"
  if [ "$FIX" = 1 ]; then
    # Free and idempotent: what tapping "TV" in the Sonos app does. Works when the
    # Beam merely dropped the source; cannot fix a failed eARC negotiation.
    note "  -> re-selecting the TV input"
    soap SetAVTransportURI "<CurrentURI>$HTASTREAM</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>" >/dev/null
    sleep 3
    uri=$(arc_uri)
    [ "$uri" = "$HTASTREAM" ] && note "  eARC UP after re-select" || note "  still down"
  fi
fi

# The AirPlay sink is a separate fault from eARC — check it either way.
note "== AirPlay sink =="
if pactl list sinks short 2>/dev/null | grep -qi 'office\|raop'; then
  note "  present"
elif [ "$FIX" = 1 ]; then
  note "  MISSING -> restarting pipewire (wireplumber alone would not restore it)"
  systemctl --user restart pipewire pipewire-pulse wireplumber
  sleep 5
  pactl list sinks short 2>/dev/null | grep -qi 'office\|raop' \
    && note "  restored" || note "  still missing — is the Beam advertising? (avahi-browse -tp _raop._tcp)"
else
  note "  MISSING"
fi

if [ "$uri" = "$HTASTREAM" ]; then
  notify "arc-kick" "eARC is up"
  exit 0
fi
note ""
note "eARC is still down, and nothing on this machine can restart it:"
note "DisplayPort carries no CEC, so only the MONITOR can re-initiate the link."
note "  -> Unplug the BenQ from the MAINS for 60s, leaving the Beam running."
note "     It does not come back instantly; re-run arc-kick a few minutes later."
notify "arc-kick" "eARC down — mains power-cycle the monitor for 60s"
exit 1
