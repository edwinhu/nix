#!/usr/bin/env bash
# PHOTOGRAPH what `o` does. The pytest gate proves a process exists; this proves
# something was PAINTED -- a floating ghostty window runs the harness proxy, grim
# captures the region before and after the keypress, and the pixels have to move.
#
# Liveness first: if the shot before `o` matches the shot before Enter, the
# capture is frozen and every later comparison is meaningless.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/../../../.."
HARNESS="$PWD/hosts/linux/omarchy/files/aerc_o_term_harness.py"
mkdir -p .craft/o-term-build

nix build '/home/eh/nix#homeConfigurations.eh.pkgs.aerc' \
  -o .craft/o-term-build/aerc
nix build '/home/eh/nix#homeConfigurations.eh.pkgs.aerc-html-terminal-browser' \
  -o .craft/o-term-build/launcher
echo "aerc:     $(readlink -f .craft/o-term-build/aerc)"
echo "launcher: $(readlink -f .craft/o-term-build/launcher)"

AERC_BIN="$PWD/.craft/o-term-build/aerc/bin/aerc"
LAUNCHER_BIN="$PWD/.craft/o-term-build/launcher/bin"

OUT="$PWD/.craft/o-term-shots"
rm -rf "$OUT"; mkdir -p "$OUT"

FIXROOT="$(mktemp -d -t o-term-shot-XXXXXX)"
trap 'rm -rf "$FIXROOT"' EXIT
ACCOUNTS="$(python3 "$HARNESS" fixture --out "$FIXROOT")"
echo "fixture accounts: $ACCOUNTS"

# DOTTED CLASS, because ghostty's --class must be a valid GTK application id --
# a bare "aerc-o-term-shot" is silently dropped and the window comes up as
# com.mitchellh.ghostty, which no `hyprctl clients` filter can then find.
CLASS=dev.aerc.oterm.shot
# OPEN WITH `o`, NOT ENTER. binds.conf binds both to :view in [messages], but a
# bare CR through a REAL ghostty lands in the reply composer instead -- measured
# three times, with nvim's own OSC 11 query coming back 50ms after the keypress.
# (The pty harness's fake terminal does not negotiate the kitty keyboard
# protocol and there Enter opens the viewer, which is why this only bites here.)
# `o` is :view in the list and the launcher in the viewer, so the same key does
# both steps.
KEYS='6:o,12:o,45:q,50::quit\r'

# `hyprctl dispatch exec '[rules] cmd'` is the OLD spelling: this build parses
# the argument as Lua, so it fails on the rule brackets and still exits 0.
# exec_cmd takes the whole string, and [[...]] keeps bash quoting out of Lua.
#
# ghostty inherits the dispatcher's environment, but say it explicitly rather
# than depend on it: the launcher bin must come first or `o` finds nothing.
hyprctl dispatch "hl.dsp.exec_cmd[[[float;size 1400 900;center] \
ghostty --class=$CLASS -e \
env PATH=$LAUNCHER_BIN:$PATH python3 $HARNESS proxy \
--aerc $AERC_BIN --accounts $ACCOUNTS --keys $KEYS \
--report $OUT/report.json --watch terminal-browser]]"

START=$(date +%s)
GEO=""
for _ in $(seq 1 40); do
  GEO=$(hyprctl clients -j | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    if c.get("class") == "'"$CLASS"'":
        print(c["at"][0], c["at"][1], c["size"][0], c["size"][1]); break
')
  [ -n "$GEO" ] && break
  sleep 0.5
done
if [ -z "$GEO" ]; then
  echo "FAIL: no $CLASS window appeared within 20s"; exit 1
fi
read -r X Y W H <<<"$GEO"
echo "window: ${W}x${H} at ${X},${Y}"

shoot() {  # shoot <at-seconds> <name>
  local target=$1 name=$2 now
  while :; do
    now=$(( $(date +%s) - START ))
    [ "$now" -ge "$target" ] && break
    sleep 0.3
  done
  grim -g "$X,$Y ${W}x${H}" "$OUT/$name.png"
  echo "shot $name at t=$(( $(date +%s) - START ))s"
}

shoot 4 list
shoot 10 before
shoot 30 after

for _ in $(seq 1 140); do
  hyprctl clients -j | grep -q "\"$CLASS\"" || break
  sleep 0.5
done
hyprctl clients -j | grep -q "\"$CLASS\"" && \
  hyprctl dispatch closewindow "class:$CLASS" || true

hash_of() { sha256sum "$1" | cut -d' ' -f1; }
LIST=$(hash_of "$OUT/list.png")
BEFORE=$(hash_of "$OUT/before.png")
AFTER=$(hash_of "$OUT/after.png")

SEEN=false
if [ -f "$OUT/report.json" ]; then
  SEEN=$(python3 -c '
import json, sys
print(str(json.load(open(sys.argv[1])).get("seen", False)).lower())
' "$OUT/report.json")
fi

python3 - "$OUT/summary.json" <<PY
import json, sys
json.dump({
    "hashes": {"list": "$LIST", "before": "$BEFORE", "after": "$AFTER"},
    "window": {"x": $X, "y": $Y, "w": $W, "h": $H},
    "liveness": "$LIST" != "$BEFORE",
    "changed_after_o": "$BEFORE" != "$AFTER",
    "watched_process_seen": "$SEEN" == "true",
}, open(sys.argv[1], "w"), indent=2)
PY
cat "$OUT/summary.json"

if [ "$LIST" = "$BEFORE" ]; then
  echo "FAIL: capture is frozen -- Enter changed nothing on screen"; exit 3
fi
status=0
[ "$BEFORE" = "$AFTER" ] && { echo "FAIL: screen unchanged after o"; status=1; }
[ "$SEEN" = "true" ] || { echo "FAIL: no terminal-browser under aerc"; status=1; }
exit $status
