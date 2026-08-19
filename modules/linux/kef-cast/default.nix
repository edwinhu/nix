{ pkgs }:

# kef-cast — send this machine's audio to the KEF over Google Cast.
#
# Chromecast has no PipeWire sink and no "system audio" mode: a Cast receiver
# PULLS a URL, it is never pushed to. So the bridge is a null sink, an HTTP
# server that encodes that sink's monitor to MP3 on demand, and `catt` pointing
# the speaker at it. The speaker treats it as an internet radio station.
#
# Two dead ends worth not repeating, both tested against this speaker:
#
#   - HLS. The obvious choice, since the receiver plays a BBC m3u8 happily. It
#     fetches our playlist (master or media, live or VOD, HTTP/1.0 or 1.1) and
#     then never requests a single segment. Not pursued further because the
#     plain MP3 stream below works and has less latency.
#   - mkchromecast, the off-the-shelf tool for exactly this. Its device scan
#     returns nothing here, `play` times out against the receiver, and it leaks
#     its null sink on every run.
#
# Needs inbound TCP on $KEF_CAST_PORT from the LAN, since the speaker is the one
# connecting. ufw runs on this host and has a matching rule:
#     ufw allow from 192.168.4.0/22 to any port 8099 proto tcp
# Without it the cast is accepted and the speaker then silently never connects,
# which looks exactly like a codec problem and is not one.
#
# That port is an unauthenticated capture endpoint: while this runs, anything on
# the LAN that GETs it hears this machine's audio. Scoped to the LAN by the ufw
# rule and gone the moment you Ctrl-C, but do not widen the rule.

pkgs.writeShellApplication {
  name = "kef-cast";

  runtimeInputs = with pkgs; [
    catt
    ffmpeg
    iproute2
    pulseaudio # pactl
    python3
    (import ../../shared/kefctl.nix { inherit pkgs; })
  ];

  text = ''
    DEVICE="''${KEF_CAST_DEVICE:-LSX II LT-07148c}"
    PORT="''${KEF_CAST_PORT:-8099}"
    SINK=kefcast

    SPEAKER_IP="$(kefctl ip)"
    # Whichever local address routes to the speaker — the URL has to be
    # reachable FROM the speaker, so localhost is useless here.
    LAN_IP="$(ip -4 route get "$SPEAKER_IP" |
      awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i+1); exit }}')"

    MODULE=""
    SRVPID=""
    CASTING=""
    CLEANED=""
    LOG=""
    cleanup() {
      set +e
      # INT fires this and then EXIT fires it again; without the guard that is a
      # second `catt stop` round-trip on the way out.
      [ -n "$CLEANED" ] && return
      CLEANED=1
      [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
      # ONLY if this process started the cast. Stopping unconditionally would
      # kill whatever else the speaker happens to be playing whenever this
      # script fails early — someone else's Spotify, or the first kef-cast if
      # you accidentally start a second one.
      [ -n "$CASTING" ] && catt -d "$DEVICE" stop >/dev/null 2>&1
      # Unload by module id, not by name: leaving null sinks behind is exactly
      # what makes mkchromecast unpleasant to live with.
      [ -n "$MODULE" ] && pactl unload-module "$MODULE" 2>/dev/null
      [ -n "$LOG" ] && rm -f "$LOG"
    }
    trap cleanup EXIT INT TERM

    MODULE="$(pactl load-module module-null-sink sink_name=$SINK \
      sink_properties=device.description=KEF-Cast)"

    LOG="$(mktemp)"
    python3 ${./serve.py} "$PORT" "$SINK.monitor" > "$LOG" 2>&1 &
    SRVPID=$!

    # Wait for the server to say it bound, rather than sleeping at it. Do NOT
    # replace this with a connect probe: on a port collision the probe reaches
    # the process that already owns the port and reports success, so a second
    # kef-cast would cast — and its cleanup would then stop the FIRST one's
    # playback. Measured doing exactly that before this was fixed.
    ready() { grep -q '^ready$' "$LOG"; }
    for _ in $(seq 1 100); do
      ready && break
      if ! kill -0 "$SRVPID" 2>/dev/null; then
        echo "kef-cast: stream server failed to start:" >&2
        cat "$LOG" >&2
        exit 1
      fi
      sleep 0.1
    done
    if ! ready; then
      echo "kef-cast: stream server did not come up within 10s:" >&2
      cat "$LOG" >&2
      exit 1
    fi

    # The .mp3 suffix is load-bearing: catt guesses the content type from the
    # URL, and the receiver needs to be told audio/mpeg. -f skips catt's yt-dlp
    # extractor, which treats a bare host:port URL as a site to scrape and fails
    # before it ever reaches the speaker.
    catt -d "$DEVICE" cast -f --stream-type live "http://$LAN_IP:$PORT/stream.mp3"
    CASTING=1

    echo
    echo "Casting to $DEVICE. Point players at the '$SINK' sink:"
    echo "    cliamp device $SINK"
    echo "Ctrl-C to stop and tear it all down."
    wait "$SRVPID"
  '';

  meta = {
    description = "Bridge this machine's audio to a KEF speaker over Google Cast";
    mainProgram = "kef-cast";
  };
}
