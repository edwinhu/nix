#!/usr/bin/env bash
# Both inputs, measured INSIDE aerc's o viewer, from pixels on the screen.
#
# Wheel injection goes through the browser's own CDP port, because ydotool has no wheel verb; the
# recorder then counts frames that actually reached the pane, which is the only number the user
# feels. Keys are held with the compositor's send_shortcut, as the harness does.
set -uo pipefail

# THE COMPOSITOR ENVIRONMENT, BORROWED. A Stop hook and an ssh shell both run this with no
# WAYLAND_DISPLAY and no HYPRLAND_INSTANCE_SIGNATURE, and without them hyprctl returns non-JSON,
# jq spews parse errors and desktop.sh reports "test session window never appeared" -- which reads
# as a broken instrument rather than a missing variable.
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  __g=$(pgrep -f "ghostty.*herdr" 2>/dev/null | head -1)
  if [ -n "${__g:-}" ]; then
    eval "$(tr '\0' '\n' < /proc/"$__g"/environ \
      | grep -E "^(WAYLAND_DISPLAY|HYPRLAND_INSTANCE_SIGNATURE|XDG_RUNTIME_DIR|DISPLAY|DBUS_SESSION_BUS_ADDRESS)=" \
      | sed "s/^/export /")"
  fi
fi

SCRIPTS=/home/eh/nix/.claude/skills/aerc-scroll-gif/scripts
. "$SCRIPTS/desktop.sh"
OUT=${1:-/home/eh/nix/.craft/o-both-inputs}
TB="$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
mkdir -p "$OUT"; R="$OUT/report.md"; : > "$R"
log() { printf '%s\n' "$*" | tee -a "$R"; }

for t in hyprctl jq gpu-screen-recorder ffprobe notmuch python3 bun; do
  command -v "$t" >/dev/null || { log "missing tool $t"; exit 3; }
done

test_session_ensure || { log "no test session"; exit 3; }
log "test window $TEST_ADDR geo $TEST_GEO"

timeout 30 "$TB" shutdown >/dev/null 2>&1      # own the daemon: transport is fixed at its start
A=$(nix build /home/eh/nix#homeConfigurations.eh.pkgs.aerc --print-out-paths --no-link 2>/dev/null)/bin/aerc
[ -x "$A" ] || { log "could not build aerc"; exit 3; }

# OWN A FRESH TAB. Reusing whatever pane is in the test workspace types aerc's name into an aerc
# that is already running, or into the frozen last frame of a dead one -- both look like "the filter
# never produced a message list". A new tab is always a live shell.
# FOCUSED, deliberately: the test window displays only its ACTIVE tab, so a --no-focus tab runs
# aerc and o in something never painted and the recorder counts 0 changed frames -- which is
# indistinguishable from "catastrophically slow". This focus is inside the test herdr session and
# does not move Hyprland focus away from the user.
TAB=$(h tab create --workspace "$TEST_WS" --cwd "$HOME" --label fps-gate 2>/dev/null \
  | jq -r '.result.tab.tab_id // empty')
[ -n "${TAB:-}" ] && h tab focus "$TAB" >/dev/null 2>&1
PANE=$(h pane list 2>/dev/null | jq -r --arg t "$TAB" '[.result.panes[] | select(.tab_id==$t) | .pane_id][0] // empty')
[ -n "${PANE:-}" ] || { log "could not create a fresh tab in the test workspace"; exit 3; }
cleanup_tab() { [ -n "${TAB:-}" ] && h tab close "$TAB" >/dev/null 2>&1; }
trap cleanup_tab EXIT

# SURFACE=plain runs terminal-browser straight into the pane with the launcher's own flags and
# preload, skipping aerc entirely. Same recorder, same region, same wheel driver -- so the only
# difference from the o path is aerc's tty handover, which is what makes the comparison decisive.
if [ "${SURFACE:-o}" = plain ]; then
  # THE SAME MESSAGE BOTH SURFACES SEE. A synthetic text page measured 17 changed frames where the
  # real email measured 106 in the same configuration: ffprobe scores frame-to-frame difference, so
  # a sparse page under 5px eased steps falls under the threshold and the number says more about the
  # fixture than the pipeline. Serve the mail the o path opens, or the comparison is not a comparison.
  MSGFILE=$(notmuch search --output=files from:arcteryx 2>/dev/null | head -1)
  [ -r "${MSGFILE:-}" ] || { log "no message file for the plain surface"; exit 3; }
  aerc-mail-serve < "$MSGFILE" >/dev/null 2>&1 9>&-
  URL=$(sed -n 1p "${XDG_RUNTIME_DIR:-/tmp}/aerc-mail-browser-url" 2>/dev/null)
  [ -n "${URL:-}" ] || { log "aerc-mail-serve gave no URL"; exit 3; }
  PRELOAD=$(grep -oE "/nix/store/[^ \"]+aerc-pager-keys(-fps)?\.js" "$(readlink -f "$HOME/.nix-profile/bin/aerc-mail-tty")" 2>/dev/null | head -1)
  cat > "$OUT/plain.sh" <<PLAINEOF
#!/usr/bin/env bash
exec "\$HOME/.local/share/terminal-browser/app/bin/terminal-browser" open file://$OUT/page.html \
  ${PLAIN_FLAGS-"--app-mode --app-name=fps-gate --no-toolbar --no-frame --no-overlays --no-context-menu --preload=$PRELOAD"}
PLAINEOF
  chmod +x "$OUT/plain.sh"
  h pane run "$PANE" "$OUT/plain.sh" >/dev/null 2>&1
  for _ in $(seq 1 30); do
    [ "$(pgrep -f '[t]erminal-browser/app' 2>/dev/null | wc -l)" -gt 0 ] && break
    sleep 1
  done
  sleep "${SETTLE:-10}"
else
h pane run "$PANE" "$A" >/dev/null 2>&1
h pane wait-output "$PANE" --regex 'Inbox|INBOX|Personal|Work' --timeout 25000 >/dev/null || { log "aerc UI never appeared"; exit 3; }
sleep 2

# READ THE PANE TO DECIDE STATE, NEVER A TIMER. Enter in [view] is `:reply -a`: one Enter too many
# opens a reply composer to the newsletter, and every later keystroke is typed into its body.
h pane send-text "$PANE" ":filter from:arcteryx"; h pane send-keys "$PANE" enter
h pane wait-output "$PANE" --regex "Arc.teryx" --timeout 20000 >/dev/null \
  || { log "the filter never produced a message list"; exit 3; }

h pane send-keys "$PANE" enter                                # [messages] -> [view], exactly once
h pane wait-output "$PANE" --regex "text/html|text/plain" --timeout 20000 >/dev/null \
  || { log "the message viewer never opened"; exit 3; }
if h pane read "$PANE" --source visible --lines 3 2>/dev/null | grep -qi "INSERT\|compose"; then
  log "a composer is open -- refusing to continue"; exit 3
fi

h pane send-text "$PANE" "o"                                  # hand the tty to terminal-browser
for _ in $(seq 1 30); do
  [ "$(pgrep -f '[t]erminal-browser/app' 2>/dev/null | wc -l)" -gt 0 ] && break
  sleep 1
done
[ "$(pgrep -f '[t]erminal-browser/app' 2>/dev/null | wc -l)" -gt 0 ] \
  || { log "terminal-browser never started after o"; exit 3; }
# LET THE PAGE FINISH ARRIVING. Frames take several seconds to appear after o, and measuring early
# scrolls a page that has not painted yet -- which reads as a slow pipeline.
sleep "${SETTLE:-10}"
fi
log "terminal-browser processes after o: $(pgrep -f '[t]erminal-browser/app' | wc -l)"

# The o-launched browser does not always register in `ls`, so fall back to probing the CDP ports
# its electron processes are listening on.
PORT=$(timeout 20 "$TB" ls --json 2>/dev/null | jq -r '.browsers[0].cdpPort // empty')
if [ -z "${PORT:-}" ]; then
  # Read the port off the browser's own command line rather than scanning: a scan found collie's
  # bridge on 8790 and called it a browser.
  for pid in $(pgrep -f "[t]erminal-browser/app/electron" 2>/dev/null); do
    cand=$(tr '\0' ' ' < /proc/"$pid"/cmdline 2>/dev/null | grep -oE "remote-debugging-port=[0-9]+" | cut -d= -f2 | head -1)
    if [ -n "${cand:-}" ] && curl -s --max-time 2 "http://127.0.0.1:$cand/json/list" 2>/dev/null | grep -q webSocketDebuggerUrl; then
      PORT=$cand; break
    fi
  done
fi
log "cdp port inside o: ${PORT:-none}"

measure() {   # label, driver-command
  local label=$1 driver=$2 mp4="$OUT/$1.mp4"
  rm -f "$mp4"
  gpu-screen-recorder -w region -region "$TEST_GEO" -f 60 -a "" -o "$mp4" > "$OUT/gsr-$1.log" 2>&1 & local gsr=$!
  sleep 1.5
  eval "$driver"
  sleep 1.0
  kill -INT "$gsr" 2>/dev/null; wait "$gsr" 2>/dev/null
  [ -s "$mp4" ] || { log "$label: no video"; return 1; }
  local frames
  frames=$(ffprobe -v error -f lavfi -i "movie=$mp4,select=gt(scene\,0.0005)" -show_entries frame=pts_time -of csv=p=0 2>/dev/null | wc -l)
  log "$label: $frames changed frames over ~3 s = ~$((frames / 3)) fps"
}

# KEYS HELD are reported for context only: the pager preload makes them discrete on purpose, so
# their frame count is not a defect and is not gated.
measure keys-held 'hl_hold "$TEST_ADDR" Down 3'

# THE GATE: the WHEEL, which IS meant to be smooth. Continuous ticks 50ms apart, a real flick,
# injected over the browser CDP port because ydotool has no wheel verb. The number is frames that
# reached the SCREEN -- the page eases at 60 fps and the browser emits ~58, so anything lost here is
# lost between the browser and the pane.
[ -n "${PORT:-}" ] || { log "wheel: could not reach a cdp port inside o"; exit 3; }
measure wheel "timeout 60 bun $SCRIPTS/wheel-probe.ts --ticks 55 --gap 50 --port $PORT >> $R 2>&1 || true"

WHEEL_FRAMES=$(grep -oE "^wheel: [0-9]+" "$R" | grep -oE "[0-9]+" | tail -1)
[ -n "${WHEEL_FRAMES:-}" ] || { log "no wheel frame count"; exit 3; }
MIN=${MIN_WHEEL_FRAMES:-90}
log "wheel gate: $WHEEL_FRAMES changed frames in 3 s, target $MIN (~$((MIN / 3)) fps)"
log DONE
[ "$WHEEL_FRAMES" -ge "$MIN" ] && exit 0
exit 1
