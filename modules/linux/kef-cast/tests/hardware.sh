#!/usr/bin/env bash
# Hardware acceptance for kef-cast — the one test that touches the real speaker.
#
# The stand-in suite in run.sh proves the watchdog logic against a fake receiver.
# It cannot prove the thing that actually broke: that THIS speaker, after the
# session dies, accepts a fresh cast and starts pulling again. That is what this
# checks, on the production path, with nothing stubbed.
#
# It interrupts whatever the speaker is playing. It also needs the speaker awake
# on the LAN and the ufw rule for the stream port in place. If the speaker is
# unreachable this FAILS rather than skipping — a silent skip in an acceptance
# check is indistinguishable from a pass.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
DEVICE="${KEF_CAST_DEVICE:-LSX II LT-07148c}"
PORT="${KEF_CAST_PORT:-8099}"

nix_build() {
  nix build --no-link --print-out-paths --impure --expr "$1" 2>/dev/null | tail -1
}

STORE=$(nix_build "let f = builtins.getFlake \"$ROOT\"; pkgs = f.homeConfigurations.eh.pkgs; in import $ROOT/modules/linux/kef-cast { inherit pkgs; }")
CATT=$(nix_build "let f = builtins.getFlake \"$ROOT\"; pkgs = f.homeConfigurations.eh.pkgs; in pkgs.catt")
KEFCTL=$(nix_build "let f = builtins.getFlake \"$ROOT\"; pkgs = f.homeConfigurations.eh.pkgs; in import $ROOT/modules/shared/kefctl.nix { inherit pkgs; }")
if [ -z "$STORE" ] || [ ! -x "$STORE/bin/kef-cast" ] || [ ! -x "$CATT/bin/catt" ] || [ ! -x "$KEFCTL/bin/kefctl" ]; then
  echo "could not build kef-cast, catt or kefctl" >&2
  exit 127
fi

# kefctl, NOT the wrapper: kef-cast takes no arguments and ignores any it is
# given, so asking it for an IP would start a real cast as a side effect.
SPEAKER_IP=$("$KEFCTL/bin/kefctl" ip 2>/dev/null)
[ -n "$SPEAKER_IP" ] || SPEAKER_IP=192.168.4.190

if ! timeout 10 ping -c1 -W2 "$SPEAKER_IP" >/dev/null 2>&1; then
  echo "FAIL: speaker $SPEAKER_IP is not reachable — cannot accept this change without it" >&2
  exit 1
fi

WRAPPER_PID=""
cleanup() {
  [ -n "$WRAPPER_PID" ] && kill "$WRAPPER_PID" 2>/dev/null
  sleep 1
}
trap cleanup EXIT

attached() { ss -tn state established 2>/dev/null | grep -q "$SPEAKER_IP.*:$PORT\|:$PORT.*$SPEAKER_IP"; }

wait_until() {  # $1 seconds, rest: condition
  local limit=$1; shift
  local end=$(( $(date +%s) + limit ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if eval "$@"; then return 0; fi
    sleep 1
  done
  return 1
}

LOG=$(mktemp)
"$STORE/bin/kef-cast" > "$LOG" 2>&1 &
WRAPPER_PID=$!

echo "waiting for the speaker to attach to the stream..."
wait_until 45 attached || {
  echo "FAIL: speaker never attached to the stream; log:" >&2; cat "$LOG" >&2; exit 1
}
echo "  ok: attached"

echo "forcing a receiver-side drop (catt stop)..."
"$CATT/bin/catt" -d "$DEVICE" stop >/dev/null 2>&1
wait_until 20 '! attached' || {
  echo "FAIL: the connection survived catt stop — the test did not reproduce a drop" >&2; exit 1
}
echo "  ok: dropped"

echo "waiting for the bridge to recover..."
wait_until 45 attached || {
  echo "FAIL: the bridge did not re-cast and the speaker never came back; log:" >&2
  cat "$LOG" >&2
  exit 1
}
echo "  ok: recovered"

echo "PASS"
