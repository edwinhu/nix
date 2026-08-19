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
    coreutils # timeout, date, mktemp — `timeout` is load-bearing below
    ffmpeg
    iproute2
    pulseaudio # pactl
    python3
    (import ../../shared/kefctl.nix { inherit pkgs; })
  ];

  text = ''
    # Ctrl-C has to reach us before any trap can matter. A process started as an
    # async job by a shell without job control inherits SIGINT and SIGQUIT as
    # SIG_IGN (POSIX), and bash then REFUSES to trap a signal that was ignored on
    # entry — so `trap ... INT` silently does nothing and the bridge survives
    # Ctrl-C with the sink loaded and the capture port open. Verified on the
    # built wrapper: SigIgn carried bit 2 and SigCgt did not.
    #
    # A disposition of SIG_IGN survives exec, so this cannot be undone from
    # inside bash; hand off to something that CAN set it back and exec straight
    # into ourselves. python3 is already a runtime input for the stream server.
    # SIGPIPE/SIGXFSZ are in the list because python ignores those at startup and
    # they would otherwise be inherited by the encoder.
    if [ -z "''${KEF_CAST_SIGDFL:-}" ] && [ -x "$0" ]; then
      export KEF_CAST_SIGDFL=1
      exec python3 -c 'import os, signal, sys
for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGPIPE, signal.SIGXFSZ):
    signal.signal(s, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])' "$0" "$@"
    fi

    DEVICE="''${KEF_CAST_DEVICE:-LSX II LT-07148c}"
    PORT="''${KEF_CAST_PORT:-8099}"
    SINK=kefcast
    # Seconds of "no receiver attached" tolerated before re-casting. Has to be
    # longer than a normal between-request reconnect and shorter than anyone's
    # patience for silence. Measured: at 15 a drop cost 17s of silence and the
    # listener switched outputs before recovery finished. At 3 it costs ~6s, of
    # which ~4s is Cast handshake we do not control.
    GRACE="''${KEF_CAST_RECAST_AFTER:-3}"
    # 3 -> 6 -> 12. A speaker in standby ignores casts for as long as it likes;
    # retrying every GRACE seconds forever would just be a slow flood.
    RETRY_MAX=$((GRACE * 4))
    # How long to keep trying before concluding nobody is ever going to answer.
    # This bounds the window in which a cast that never worked leaves the
    # unauthenticated LAN capture port listening; it applies ONLY until the first
    # receiver attaches. After that the watchdog retries forever, because that is
    # the drop-recovery case this whole thing exists for.
    GIVE_UP="''${KEF_CAST_GIVE_UP:-300}"
    # catt is a blocking pychromecast round-trip and it does hang: measured
    # blocking past 25s during investigation. It now runs from a 1 Hz loop, so an
    # unbounded call freezes the drain, the give-up check and attach detection for
    # its whole duration. Bound it; a timeout is just a failed cast.
    CAST_TIMEOUT="''${KEF_CAST_TIMEOUT:-20}"

    stamp() { date '+%Y-%m-%d %H:%M:%S'; }
    event() { echo "$(stamp) kef-cast: $*"; }

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
    # shellcheck disable=SC2329
    # The `trap` below is the invocation. shellcheck 0.11 stops crediting it once
    # the script can no longer fall off its end, which it now cannot: the tail
    # exits with the stream server's status.
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
    # shellcheck disable=SC2329
    # Cleaning up from the trap is not enough on its own: a bash handler RETURNS
    # and the script carries straight on. Measured — SIGINT left the bridge alive
    # past 12s with the sink loaded, the cast running and the capture port open,
    # and it re-cast again afterwards. So reset the dispositions and re-raise, so
    # the process actually dies of the signal and reports the conventional 128+N
    # to whatever supervises it.
    on_signal() {
      local sig="$1" num="$2"
      cleanup
      trap - EXIT INT TERM
      kill -s "$sig" "$$"
      # Only reached if the re-raise somehow does not land.
      exit $((128 + num))
    }
    trap cleanup EXIT
    trap 'on_signal INT 2' INT
    trap 'on_signal TERM 15' TERM

    MODULE="$(pactl load-module module-null-sink sink_name=$SINK \
      sink_properties=device.description=KEF-Cast)"

    LOG="$(mktemp)"
    # serve.py reads KEF_CAST_BITRATE from this environment (default 96k).
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
    URL="http://$LAN_IP:$PORT/stream.mp3"
    cast_once() {
      local rc=0
      # -k sends KILL if catt ignores the TERM, so a wedged pychromecast cannot
      # outlive the bound either.
      timeout -k 5 "$CAST_TIMEOUT" \
        catt -d "$DEVICE" cast -f --stream-type live "$URL" || rc=$?
      if [ "$rc" -eq 0 ]; then
        # Only now: cleanup's `catt stop` is gated on this, and a cast that was
        # never accepted is not ours to stop.
        CASTING=1
        event "cast accepted by $DEVICE"
        return 0
      fi
      # 124 = TERM'd at the deadline, 137 = needed the follow-up KILL. Either way
      # it is a failed cast and the caller backs off exactly as for a refusal.
      if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        event "cast to $DEVICE TIMED OUT after ''${CAST_TIMEOUT}s"
      else
        event "cast to $DEVICE FAILED"
      fi
      return 1
    }

    # A failed first cast is no longer fatal — the speaker is often just asleep,
    # and the watchdog below is exactly the thing that keeps trying. The port
    # collision check above still exits before reaching here, so this never
    # hijacks another kef-cast's session.
    event "casting $URL to $DEVICE"
    cast_once || true

    echo
    echo "Casting to $DEVICE. Point players at the '$SINK' sink:"
    echo "    cliamp device $SINK"
    echo "Ctrl-C to stop and tear it all down."

    # ---- watchdog -----------------------------------------------------------
    # The receiver drops the stream on its own, for reasons we cannot yet name,
    # and nothing upstream announces it. serve.py prints `clients=N` on every
    # attach and detach; this reads that stream of transitions and re-casts when
    # the count has been 0 for too long.
    #
    # Read INCREMENTALLY through a held fd rather than re-grepping the log each
    # second: over a multi-day session the log only grows, and a rescan would
    # grow with it. `read` on a regular file returns at EOF without blocking and
    # leaves the offset, so this is `tail -f` with no extra process.
    CLIENTS=0
    # Tracked SEPARATELY from CLIENTS, and it is this one that gates recovery.
    # The port is unauthenticated, so the total includes any LAN host that GETs
    # it; a stranger holding a connection keeps the total above zero, and a
    # watchdog reading the total would then never see the SPEAKER leave — silent
    # playback for the rest of the session with the capture port still open.
    # CLIENTS keeps its old job: suppressing a spurious re-cast while anyone is
    # still pulling the stream.
    SPEAKERS=0
    IDLE=0
    RETRY="$GRACE"
    PARTIAL=""
    EVER=""
    STARTED="$(date +%s)"
    exec 3< "$LOG"

    on_line() {
      local n="" peer="" tok=""
      case "$1" in
        clients=*) ;;
        *) return 0 ;;
      esac
      # `clients=N peer=<ip>`; read both fields by name so the order and any
      # future field cannot silently change what this believes.
      for tok in $1; do
        case "$tok" in
          clients=*) n="''${tok#clients=}" ;;
          peer=*) peer="''${tok#peer=}" ;;
        esac
      done
      case "$n" in ""|*[!0-9]*) return 0 ;; esac
      if [ "$n" -gt "$CLIENTS" ]; then
        # The stream port is unauthenticated: ANY LAN host can GET it. Only the
        # speaker's own address may latch EVER — otherwise one stranger's
        # request switches the give-up rule off for the life of the process and
        # the capture port stays open forever, which is what give-up exists to
        # prevent. The count itself still moves below, so a stranger holding a
        # connection still suppresses a spurious re-cast exactly as before.
        if [ "$peer" = "$SPEAKER_IP" ]; then
          SPEAKERS=$((SPEAKERS + 1))
          event "receiver attached from $peer (clients=$n speakers=$SPEAKERS)"
          # Retries are unbounded from here on.
          EVER=1
          # A live receiver means the last cast worked: start over from the short
          # interval so the next drop is caught quickly.
          IDLE=0
          RETRY="$GRACE"
        else
          event "non-speaker client attached from $peer (clients=$n) — give-up rule unchanged"
        fi
      elif [ "$n" -lt "$CLIENTS" ]; then
        if [ "$peer" = "$SPEAKER_IP" ]; then
          [ "$SPEAKERS" -gt 0 ] && SPEAKERS=$((SPEAKERS - 1))
          event "receiver dropped from $peer (clients=$n speakers=$SPEAKERS)"
          # Start the idle window at the speaker's departure, not at the moment
          # the last stranger happens to hang up.
          [ "$SPEAKERS" -eq 0 ] && IDLE=0
        else
          event "non-speaker client dropped from $peer (clients=$n)"
        fi
      fi
      CLIENTS="$n"
    }

    drain() {
      # set -u: `read` stopped by EOF may leave this untouched.
      local line=""
      while IFS= read -r -u 3 line; do
        on_line "$PARTIAL$line"
        PARTIAL=""
      done
      # A read stopped by EOF still yields whatever it got; hold it until the
      # rest of the line lands rather than acting on half a number.
      PARTIAL="$PARTIAL$line"
    }

    while kill -0 "$SRVPID" 2>/dev/null; do
      # Sleep first, so IDLE counts elapsed seconds rather than loop passes and
      # KEF_CAST_RECAST_AFTER is the interval it claims to be.
      sleep 1
      drain
      # Elapsed wall clock, not a count of loop passes: a laptop that suspends
      # mid-session must not silently extend the window the port stays open.
      if [ -z "$EVER" ] && [ $(($(date +%s) - STARTED)) -ge "$GIVE_UP" ]; then
        event "no receiver attached within ''${GIVE_UP}s — giving up and closing the stream port"
        # The EXIT trap does the teardown: kill the server, stop the cast if we
        # ever owned one, unload the null sink by module id.
        exit 1
      fi
      # SPEAKERS, not CLIENTS: the speaker being gone is what silence means, and
      # a stranger on the unauthenticated port must not be able to mask it.
      if [ "$SPEAKERS" -eq 0 ]; then
        IDLE=$((IDLE + 1))
        if [ "$IDLE" -ge "$RETRY" ]; then
          event "no receiver for ''${IDLE}s — re-casting (clients=$CLIENTS)"
          cast_once || true
          IDLE=0
          RETRY=$((RETRY * 2))
          if [ "$RETRY" -gt "$RETRY_MAX" ]; then RETRY="$RETRY_MAX"; fi
          event "next re-cast in ''${RETRY}s if no receiver attaches"
        fi
      fi
    done
    # The loop replaced `wait "$SRVPID"`, which used to carry the stream server's
    # exit code out of this script; falling off the end here reports a crashed
    # encoder as a clean shutdown to whatever supervises this process.
    SRVRC=0
    wait "$SRVPID" 2>/dev/null || SRVRC=$?
    # The server going away while the bridge is still up is a failure however it
    # went, so a zero status must not read as a clean shutdown either.
    if [ "$SRVRC" -eq 0 ]; then SRVRC=1; fi
    event "stream server exited (status $SRVRC) — shutting down"
    exit "$SRVRC"
  '';

  meta = {
    description = "Bridge this machine's audio to a KEF speaker over Google Cast";
    mainProgram = "kef-cast";
  };
}
