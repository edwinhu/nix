#!/usr/bin/env bash
# The frame-rate gate against a FRESHLY BUILT aerc on the path the user runs OUTSIDE herdr: aerc
# in its own ghostty window, everything it writes captured by script(1), keys delivered to that
# window by Hyprland send_shortcut (no focus change, no ydotool). During a 3 s held ↓ in `o` the
# a=T frames are counted. Plain terminal-browser writes ~100 in that window (2026-09-13).
# Exit: 0 enough file-media frames, 2 inline-pixels, 3 unmeasured/pipeline, 4 too few frames.
#   check-rate-built.sh [--min-frames N] [--out <dir>] [--aerc <bin>]
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/desktop.sh"
OUT=/home/eh/nix/.craft/scroll-rate-check; MIN_FRAMES=60; AERC=""; QUERY="from:arcteryx"
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift 2 ;; --min-frames) MIN_FRAMES="$2"; shift 2 ;; --aerc) AERC="$2"; shift 2 ;; *) echo "unknown flag: $1" >&2; exit 3 ;; esac; done
mkdir -p "$OUT" /home/eh/nix/.craft/o-term-build; R="$OUT/report.md"; : > "$R"
log() { printf '%s\n' "$*" | tee -a "$R"; }
fail() { log "FAILED: $*"; log DONE; exit 3; }
if [ -z "$AERC" ]; then
  nix build '/home/eh/nix#homeConfigurations.eh.pkgs.aerc' -o /home/eh/nix/.craft/o-term-build/aerc-rate || exit 3
  AERC=/home/eh/nix/.craft/o-term-build/aerc-rate/bin/aerc
fi
log "aerc under test: $(readlink -f "$AERC")"
for t in ghostty hyprctl jq script notmuch python3; do command -v "$t" >/dev/null || fail "missing tool $t"; done
desktop_lock || fail "another desktop check held the lock for 15 min"

CLASS="dev.aerc.rate.r$$"; rm -f "$OUT/egress.txt"   # GTK app-id segments must not start with a digit
BEFORE=$(active_win)
setsid ghostty --gtk-single-instance=false --class="$CLASS" --window-width=1258 --window-height=1030 \
  -e script -f -q -O "$OUT/egress.txt" -c "$AERC" > "$OUT/ghostty.log" 2>&1 < /dev/null 9>&- &
ADDR=""
for _ in $(seq 60); do ADDR=$(win_addr_by_class "$CLASS"); [ -n "$ADDR" ] && break; sleep 0.25; done
[ -n "$ADDR" ] || fail "ghostty window $CLASS never appeared"
restore_focus "$BEFORE"   # the new window took focus on map; give it straight back
cleanup() { hyprctl dispatch "hl.dsp.window.close{window='address:$ADDR'}" >/dev/null 2>&1; }
trap cleanup EXIT
sleep 3
log "window $ADDR (not focused; keys via send_shortcut)"
hl_type "$ADDR" ":filter $QUERY"; hl_enter "$ADDR"; sleep 3
hl_enter "$ADDR"; sleep 3
hl_key "$ADDR" o; sleep 8
[ -s "$OUT/egress.txt" ] || fail "no egress capture (script(1) did not start?)"
log "terminal-browser processes before hold: $(pgrep -fc '[t]erminal-browser')"
S0=$(stat -c %s "$OUT/egress.txt"); hl_hold "$ADDR" Down 3; sleep 1.5
hl_key "$ADDR" q; sleep 1; hl_key "$ADDR" q; sleep 0.5
python3 - "$OUT/egress.txt" "$S0" "$OUT/verdict.json" "$MIN_FRAMES" >> "$R" 2>&1 <<'PY'
import re, sys, json, collections
data = open(sys.argv[1], 'rb').read()[int(sys.argv[2]):]
frames = []
for m in re.finditer(rb'\x1b_G([^;\x1b]*)(?:;([^\x1b]*))?\x1b\\', data):
    ks = dict(kv.split(b'=', 1) for kv in m.group(1).split(b',') if b'=' in kv)
    if ks.get(b'a') == b'T': frames.append(ks.get(b't', b'd').decode())
total = len(data); per = total // max(1, len(frames)); media = collections.Counter(frames)
min_frames = int(sys.argv[4]); fps = len(frames) / 3.0
print(f"a=T frames: {len(frames)}; media: {dict(media)}; bytes written: {total}; bytes per frame: {per}; frames/s: {fps:.1f}")
if not frames: v, code = 'unmeasured', 3
elif not (all(t in ('f', 's') for t in frames) and per < 1024): v, code = 'inline-pixels', 2
elif len(frames) < min_frames: v, code = 'too-few-frames', 4
else: v, code = 'file-media', 0
print(f"verdict: {v} (exit {code}; min-frames {min_frames})")
json.dump({'verdict': v, 'exit': code, 'frames': len(frames), 'framesPerSecond': round(fps, 1), 'minFrames': min_frames, 'media': dict(media), 'bytesPerFrame': per, 'bytesTotal': total}, open(sys.argv[3], 'w'))
PY
CODE=$(jq -r .exit "$OUT/verdict.json" 2>/dev/null || echo 3)
log DONE
exit "$CODE"
