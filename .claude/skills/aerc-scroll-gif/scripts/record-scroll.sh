#!/usr/bin/env bash
# Drive aerc's `o` (terminal-browser inside aerc's :term, kitty passthrough) scrolling an HTML
# mail and measure it — in the DEDICATED herdr test session (desktop.sh: fork-built herdr client
# in its own ghostty window), with keys delivered by Hyprland send_shortcut to that window. It
# never focuses a window, never uses ydotool, never touches the user's herdr session.
#
#   record-scroll.sh [--input tap-latency|egress|hold|keys] [--surface aerc|plain] [--aerc <bin>]
#                    [--query <notmuch query>] [--label <tab label>] [--out <dir>] [--keep-tab]
#                    [--no-review] [--verdict-json] [--min-frames N]
#
# --input tap-latency: key→screen latency, median of TAPS_N=8 single ↓ taps from a 60 fps region
#   recording; exit 0 iff median ≤ LAT_MAX=200 ms, 1 sluggish, 2 laggy, 3 unmeasured.
# --input egress: everything aerc writes to its pty is captured by script(1); during a 3 s ↓ hold
#   the kitty a=T frames are counted. Exit 0 file-media, 2 inline-pixels, 3 unmeasured; with
#   --min-frames N also 4 when fewer than N frames crossed the pty. (With the herdr sink the
#   frames go over herdr's socket, so 0 there is what check-herdr-keys-built.sh wants.)
# --input hold: a 3 s ↓ hold under a 60 fps recording, judged on displayed frames — an
#   indicative number only (the region recorder sees ~50 distinct frames/6 s even for plain
#   terminal-browser), never a gate.
# --input keys: j ×10, space ×3, k ×8 recorded and reviewed; instant jumps by design.
# The wheel mode is gone: a wheel needs the pointer over the window and steals focus.
# --surface plain runs terminal-browser straight into the test pane as the reference.
#
# Writes <out>/{report.md,verdict.json,…}; the last line of report.md is the verdict.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/desktop.sh"

QUERY="from:arcteryx"; LABEL="aerc-scroll"; OUT=""; KEEP_TAB=0; REVIEW=1; VERDICT_JSON=0; INPUT="tap-latency"; SURFACE="aerc"; AERC_BIN="aerc"; MIN_FRAMES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --input) INPUT="$2"; shift 2 ;;
    --min-frames) MIN_FRAMES="$2"; shift 2 ;;
    --surface) SURFACE="$2"; shift 2 ;;
    --aerc) AERC_BIN="$2"; shift 2 ;;
    --query) QUERY="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --keep-tab) KEEP_TAB=1; shift ;;
    --no-review) REVIEW=0; shift ;;
    --verdict-json) VERDICT_JSON=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 3 ;;
  esac
done
case "$INPUT" in tap-latency|egress|hold|keys) ;; wheel) echo "the wheel mode was removed: it needs the pointer and focus" >&2; exit 3 ;; *) echo "unknown --input $INPUT" >&2; exit 3 ;; esac
[ -n "$OUT" ] || OUT="/home/eh/nix/.craft/scroll-$INPUT-$(date +%H%M%S)"
mkdir -p "$OUT"; REPORT="$OUT/report.md"; : > "$REPORT"
log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
fail() { log "FAILED: $*"; log DONE; exit 3; }
for t in hyprctl jq gpu-screen-recorder ffmpeg ffprobe notmuch script python3; do command -v "$t" >/dev/null || fail "missing tool $t"; done
LOOK=/home/eh/projects/workflows/skills/look-at/scripts/look_at.sh

desktop_lock || fail "another desktop check held the lock for 15 min"
test_session_ensure || fail "test session unavailable"
log "test session $TEST_SESSION: window $TEST_ADDR geo $TEST_GEO workspace $TEST_WS; herdr $($TEST_HERDR_BIN --version 2>&1 | head -1)"

TAB_JSON=$(h tab create --workspace "$TEST_WS" --cwd "$HOME" --label "$LABEL" --focus) || fail "tab create"
PANE=$(jq -r '.result.root_pane.pane_id' <<<"$TAB_JSON"); TAB=$(jq -r '.result.tab.tab_id' <<<"$TAB_JSON")
cleanup() { [ "$KEEP_TAB" = 1 ] || h tab close "$TAB" >/dev/null 2>&1 || true; }
trap cleanup EXIT
sleep 1.5

if [ "$INPUT" = tap-latency ]; then
  "$HOME/.local/share/terminal-browser/app/bin/terminal-browser" shutdown >> "$REPORT" 2>&1 || fail "terminal-browser shutdown failed"
  DAEMON_DEADLINE=$((SECONDS + 10))
  while pgrep -f '/[t]erminal-browser/.*[[:space:]]--daemon([[:space:]]|$)' >/dev/null; do
    [ "$SECONDS" -lt "$DAEMON_DEADLINE" ] || fail "terminal-browser daemon did not stop in 10s"
    sleep 0.1
  done
  rm -f "$OUT/trace.txt"
fi

if [ "$SURFACE" = plain ]; then
  MSGFILE=$(notmuch search --output=files "$QUERY" | head -1); [ -r "$MSGFILE" ] || fail "no message for query '$QUERY'"
  aerc-mail-serve < "$MSGFILE" >/dev/null 2>&1 9>&-
  URL=$(sed -n 1p "${XDG_RUNTIME_DIR:-/tmp}/aerc-mail-browser-url"); [ -n "$URL" ] || fail "aerc-mail-serve gave no URL"
  # PLAIN_EXTRA lets the reference surface be run with the launcher's own flags, which is how you
  # tell a cost that belongs to aerc from one that belongs to the flags aerc passes (--app-mode,
  # the pager-keys preload, --no-overlays...). Empty by default: the reference stays the reference.
  h pane run "$PANE" "$HOME/.local/share/terminal-browser/app/bin/terminal-browser open '$URL' ''${PLAIN_EXTRA:-}"; sleep 8
else
  if [ "$INPUT" = egress ]; then
    rm -f "$OUT/egress.txt"; h pane run "$PANE" "script -f -q -O '$OUT/egress.txt' -c '$AERC_BIN'"
  elif [ "$INPUT" = tap-latency ]; then
    # Syscalls supply the auxiliary announcement metric; the recording owns the verdict.
    STRACE=$(nix build 'nixpkgs#strace' --print-out-paths --no-link 2>/dev/null)/bin/strace
    [ -x "$STRACE" ] || STRACE=$(ls -d /nix/store/*-strace-[0-9]*/bin/strace 2>/dev/null | head -1)
    [ -x "${STRACE:-/nonexistent}" ] || fail "strace unavailable for the latency measurement"
    W="$OUT/aerc-strace.sh"
    printf '%s\n' '#!/usr/bin/env bash' "exec $STRACE -f -o $OUT/trace.txt -e trace=read,write -s 120 -tt $AERC_BIN \"\$@\"" > "$W"; chmod +x "$W"
    h pane run "$PANE" "$W"
  else
    h pane run "$PANE" "$AERC_BIN"
  fi
  h pane wait-output "$PANE" --regex 'Inbox|INBOX|Personal|Work' --timeout 20000 >/dev/null || fail "aerc UI not seen in 20s"
  sleep 2
  # notmuch backend: :filter takes a query; Enter opens the viewer; `o` runs terminal-browser in :term.
  h pane send-text "$PANE" ":filter $QUERY"; h pane send-keys "$PANE" enter; sleep 3
  log "list after filter:"; h pane read "$PANE" --source visible --lines 6 | head -6 >> "$REPORT"
  h pane send-keys "$PANE" enter; sleep 3
  h pane send-text "$PANE" "o"; sleep 7
  log "viewer after o:"; h pane read "$PANE" --source visible --lines 3 | head -3 >> "$REPORT"
fi
TB_LIVE=$(pgrep -fc '[t]erminal-browser'); log "terminal-browser processes: $TB_LIVE"

# --- egress: frames on the pty during a held ↓ (keys through the test window, no focus change)
if [ "$INPUT" = egress ]; then
  [ -s "$OUT/egress.txt" ] || fail "no egress capture (script(1) did not start?)"
  S0=$(stat -c %s "$OUT/egress.txt"); hl_hold "$TEST_ADDR" Down 3; sleep 1.5
  python3 - "$OUT/egress.txt" "$S0" "$OUT/verdict.json" "$VERDICT_JSON" "$MIN_FRAMES" >> "$REPORT" 2>&1 <<'PY'
import re, sys, json, collections
data = open(sys.argv[1], 'rb').read()[int(sys.argv[2]):]
frames = []
for m in re.finditer(rb'\x1b_G([^;\x1b]*)(?:;([^\x1b]*))?\x1b\\', data):
    ks = dict(kv.split(b'=', 1) for kv in m.group(1).split(b',') if b'=' in kv)
    if ks.get(b'a') == b'T': frames.append(ks.get(b't', b'd').decode())
total = len(data); per = total // max(1, len(frames)); media = collections.Counter(frames)
min_frames = int(sys.argv[5]); fps = len(frames) / 3.0
print(f"a=T frames: {len(frames)}; media: {dict(media)}; bytes written: {total}; bytes per frame: {per}; frames/s: {fps:.1f}")
if not frames: v, code = 'unmeasured', 3
elif not (all(t in ('f', 's') for t in frames) and per < 1024): v, code = 'inline-pixels', 2
elif len(frames) < min_frames: v, code = 'too-few-frames', 4
else: v, code = 'file-media', 0
print(f"verdict: {v} (exit {code}; min-frames {min_frames})")
if sys.argv[4] == '1':
    json.dump({'verdict': v, 'exit': code, 'frames': len(frames), 'framesPerSecond': round(fps, 1), 'minFrames': min_frames, 'media': dict(media), 'bytesPerFrame': per, 'bytesTotal': total}, open(sys.argv[3], 'w'))
PY
  CODE=$(jq -r .exit "$OUT/verdict.json" 2>/dev/null || tail -1 "$REPORT" | grep -oE 'exit [0-9]' | grep -oE '[0-9]')
  log DONE; exit "${CODE:-3}"
fi

# --- tap-latency: eight single taps under a 60 fps recording of the test window
if [ "$INPUT" = tap-latency ]; then
  hl_key "$TEST_ADDR" Down; sleep 1.5      # leave the top of the page
  MP4="$OUT/scroll.mp4"; rm -f "$MP4"
  REC_START=$(date +%s.%N)
  gpu-screen-recorder -w region -region "$TEST_GEO" -f 60 -a "" -o "$MP4" > "$OUT/gsr.log" 2>&1 & GSR=$!; sleep 1.5
  kill -0 "$GSR" 2>/dev/null || fail "recorder did not start (see $OUT/gsr.log)"
  TAPS=""
  for _ in $(seq 1 "${TAPS_N:-8}"); do t=$(date +%s.%N); hl_key "$TEST_ADDR" Down; TAPS="$TAPS $t"; sleep 1.5; done
  sleep 1.0
  kill -INT "$GSR"; wait "$GSR"; log "recorder exit=$?"
  [ -s "$MP4" ] || fail "no video written (see $OUT/gsr.log)"
  LAT_MAX=${LAT_MAX:-200}
  # shellcheck disable=SC2086
  python3 "$(dirname "$(readlink -f "$0")")/judge-pixels.py" "$MP4" "$REC_START" "$LAT_MAX" $TAPS > "$OUT/taps.txt" 2>&1; CODE=$?
  ANNOUNCE_MED=none; ANNOUNCE_LAT=""
  if [ -s "$OUT/trace.txt" ]; then
    # shellcheck disable=SC2086
    ANNOUNCE=$(python3 "$(dirname "$(readlink -f "$0")")/judge-taps.py" "$OUT/trace.txt" "$LAT_MAX" $TAPS 2>&1)
    log "announcement metric (auxiliary):"; log "$ANNOUNCE"
    ANNOUNCE_MED=$(grep -oE 'median key→frame ms: [0-9]+' <<< "$ANNOUNCE" | grep -oE '[0-9]+$' || echo none)
    ANNOUNCE_LAT=$(grep -oE 'per tap: .*' <<< "$ANNOUNCE" | cut -c9-)
  fi
  log "pixel metric (ground truth):"
  cat "$OUT/taps.txt" >> "$REPORT"; cat "$OUT/taps.txt"
  MED=$(grep -oE 'median key→frame ms: [0-9]+' "$OUT/taps.txt" | grep -oE '[0-9]+$' || echo none)
  V=$(grep -oE 'verdict: [a-z]+' "$OUT/taps.txt" | cut -d' ' -f2)
  [ "$VERDICT_JSON" = 1 ] && jq -n --arg v "${V:-unmeasured}" --argjson code "$CODE" --arg med "$MED" --arg lat "$(grep -oE 'per tap: .*' "$OUT/taps.txt" | cut -c9-)" --arg announceMed "$ANNOUNCE_MED" --arg announceLat "$ANNOUNCE_LAT" '{verdict:$v, exit:$code, medianMs:($med|tonumber? // null), perTapMs:$lat, announceMedianMs:($announceMed|tonumber? // null), announcePerTapMs:(if $announceLat == "" then null else $announceLat end)}' > "$OUT/verdict.json"
  log DONE; exit "$CODE"
fi

# --- hold / keys: a recording, a changed-frame count, and an advisory Gemini review
MP4="$OUT/scroll.mp4"; rm -f "$MP4"
gpu-screen-recorder -w region -region "$TEST_GEO" -f 60 -a "" -o "$MP4" > "$OUT/gsr.log" 2>&1 & GSR=$!; sleep 1.5
if [ "$INPUT" = hold ]; then
  hl_hold "$TEST_ADDR" Down 3; sleep 1.0
  CADENCE="one held ↓ for 3 s: continuous scrolling; judge only how many distinct frames were displayed and whether motion was continuous or bunched."
else
  for _ in $(seq 1 10); do hl_key "$TEST_ADDR" j; sleep 0.3; done; sleep 0.7
  for _ in 1 2 3; do hl_key "$TEST_ADDR" space; sleep 1.0; done; sleep 0.7
  for _ in $(seq 1 8); do hl_key "$TEST_ADDR" k; sleep 0.25; done; sleep 1.2
  CADENCE="keys: j x10 at ~0.3 s, space x3 at ~1 s, k x8 at ~0.25 s. These are instant single-frame jumps BY DESIGN (pager keys); judge only frame health and latency, not easing."
fi
kill -INT "$GSR"; wait "$GSR"; log "recorder exit=$?"
[ -s "$MP4" ] || fail "no video written (see $OUT/gsr.log)"
MOTION=$(ffprobe -v error -f lavfi -i "movie=$MP4,select=gt(scene\,0.0005)" -show_entries frame=pts_time -of csv=p=0 2>/dev/null | wc -l)
log "frames with motion: $MOTION"
[ "$MOTION" -ge 5 ] || fail "no scroll motion captured ($MOTION changed frames) — the input did not reach the page"
GIF="$OUT/scroll.gif"
ffmpeg -y -v error -i "$MP4" -vf "fps=30,scale=1280:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3" "$GIF" || fail "ffmpeg gif"
ffmpeg -y -v error -ss 4.0 -i "$MP4" -frames:v 1 "$OUT/mid.png"
log "mp4: $MP4 ($(stat -c %s "$MP4") bytes); gif: $GIF ($(stat -c %s "$GIF") bytes)"
if [ "$INPUT" = hold ]; then
  log "held-key displayed frames: $MOTION over 3 s (~$((MOTION / 3)) fps) — indicative only"
  if [ "$MOTION" -ge 60 ]; then V=smooth; CODE=0; elif [ "$MOTION" -ge 30 ]; then V=mostly-smooth; CODE=1; else V=choppy; CODE=2; fi
else
  V=choppy; CODE=2   # keys are instant by design; never "smooth"
fi
log "verdict: $V (exit $CODE) — from the frame metric; the Gemini review below is advisory"
[ "$VERDICT_JSON" = 1 ] && jq -n --arg v "$V" --arg gif "$GIF" --arg mp4 "$MP4" --argjson code "$CODE" --argjson motion "$MOTION" '{verdict:$v, exit:$code, motionFrames:$motion, gif:$gif, mp4:$mp4}' > "$OUT/verdict.json"
if [ "$REVIEW" = 0 ]; then log DONE; exit "$CODE"; fi
log "== look-at mid frame"
"$LOOK" --file "$OUT/mid.png" --goal "Screenshot of a terminal (herdr) running aerc with an embedded terminal-browser pane. Is an HTML email rendered with images and formatted text in the main pane? Describe what is visible in two sentences." 2>&1 | tail -4 | tee -a "$REPORT"
log "== look-at video review (advisory)"
"$LOOK" --file "$MP4" --goal "Watch this 60 fps screen recording directly and answer from what you see — do NOT write or run any analysis scripts. An email is scrolled inside a terminal-embedded browser. Input: $CADENCE Report: (1) does the content move smoothly or in visible jumps, (2) any tearing, blank frames, or stale frames, (3) an estimate of frames per second of visible motion. Three sentences." 2>&1 | tail -6 | tee -a "$REPORT"
log DONE
exit "$CODE"
