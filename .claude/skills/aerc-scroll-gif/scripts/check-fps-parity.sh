#!/usr/bin/env bash
# NOT THE SMOOTHNESS GATE. Use check-wheel-smooth.sh for that.
#
# This measures a HELD ARROW, and aerc-pager-keys.js deliberately makes arrows discrete
# (scrollBy instant + preventDefault), so a low number here is the pager working as written, not a
# defect. Kept because the held-key rate is still the right way to see the PAGER's cost, and because
# the comparison below is what exonerated aerc and herdr. Measured 2026-09-21 on the wheel path
# instead: 5 eased positions per tick and 58 emitted frames/s under continuous scrolling.
#
# Measured 2026-09-21 on this machine, same build, same page, same held key, minutes apart:
#   standalone terminal-browser  106 changed frames / 3 s  (~35 fps)  smooth
#   under aerc o                  14 changed frames / 3 s  (~4 fps)   choppy
# That gap is NOT aerc and NOT herdr: running standalone terminal-browser with the launcher's own
# flags reproduces the same 14 frames with no aerc present, and the preload alone reproduces 5. The
# flags -- specifically the pager preload taking the keydown -- are the whole difference.
#
# The 100-frame target below is therefore NOT reachable without removing the pager semantics, which
# are wanted. Left as-is so the number keeps naming the pager's cost; do not arm a hold on it.
#
# Exit 0 met, 1 unmet (the measurement ran and came in short), 3 could-not-run.
set -uo pipefail

MIN=${FPS_MIN_FRAMES:-100}
OUT=${1:-/home/eh/nix/.craft/fps-parity}
SCRIPTS=/home/eh/nix/.claude/skills/aerc-scroll-gif/scripts

# The compositor environment. An ssh shell has none, and without it hyprctl returns non-JSON, jq
# spews parse errors and the test window never appears -- which reads as a broken instrument.
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  g=$(pgrep -f "ghostty.*herdr" | head -1)
  [ -n "${g:-}" ] || { echo "no desktop ghostty to borrow a compositor environment from" >&2; exit 3; }
  eval "$(tr '\0' '\n' < /proc/"$g"/environ \
    | grep -E "^(WAYLAND_DISPLAY|HYPRLAND_INSTANCE_SIGNATURE|XDG_RUNTIME_DIR|DISPLAY|DBUS_SESSION_BUS_ADDRESS)=" \
    | sed "s/^/export /")"
fi

A=$(nix build /home/eh/nix#homeConfigurations.eh.pkgs.aerc --print-out-paths --no-link 2>/dev/null)/bin/aerc
[ -x "$A" ] || { echo "could not build aerc from the flake" >&2; exit 3; }

rm -rf "$OUT"; mkdir -p "$OUT"
bash "$SCRIPTS/record-scroll.sh" --input hold --aerc "$A" --no-review --verdict-json --out "$OUT" \
  > "$OUT/run.log" 2>&1

F=$(jq -r ".motionFrames // empty" "$OUT/verdict.json" 2>/dev/null)
if [ -z "${F:-}" ]; then
  echo "no motionFrames in $OUT/verdict.json -- the measurement did not complete; see $OUT/run.log" >&2
  tail -3 "$OUT/run.log" >&2 2>/dev/null
  exit 3
fi

echo "held-scroll in aerc o: $F changed frames in 3 s (~$((F / 3)) fps); target $MIN (~$((MIN / 3)) fps)"
[ "$F" -ge "$MIN" ] && exit 0
exit 1
