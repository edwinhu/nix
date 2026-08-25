#!/usr/bin/env bash
# IMAP `SEARCH TEXT` must not get slower than the recorded baseline.
#
# This is the whole reason bun is pinned at all: `--compile` embeds the runtime,
# so the bun that builds mail-bridge is the bun that answers every query, and
# 1.3.13 answered these same two searches ~47x slower than 1.3.14. A bump that
# merely builds proves nothing about the thing the pin exists to protect.
#
# Measured over `archive account serve` -- the production listener, on a
# non-production port, against a BACKUP corpus. Never the live database.
#
# The comparison is INTERLEAVED against a 1.3.14 reference binary rather than
# against a stored number: the same 1.3.14 artifact measured 6% slower than its
# own recorded figures once the machine got busy, so a stored baseline gates on
# ambient load. Reference and candidate are timed back to back every round.
#
# The threshold is 1.10x, not equality. Interleaving leaves ~1% of error -- two
# runs of the same binary disagreed by that much -- so equality would decide on
# noise. 1.10x is ~5x above the noise and ~30x below the 47x regression it
# exists to catch.
set -euo pipefail

cd "$(dirname "$0")/.."
runs="${BENCH_RUNS:-7}"
port="${BENCH_PORT:-11430}"
account="${BENCH_ACCOUNT:-eddyhu@gmail.com}"
provider="${BENCH_PROVIDER:-gmail}"
baseline="scripts/search-baseline.json"

reference="${MAIL_BRIDGE_BENCH_REFERENCE:-}"
if [ -z "$reference" ]; then
  reference=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("reference",""))' "$baseline")
fi
if [ -z "$reference" ] || [ ! -x "$reference" ]; then
  echo "assert-search-benchmark: no 1.3.14 reference binary at '${reference:-<unset>}'" >&2
  echo "  set MAIL_BRIDGE_BENCH_REFERENCE, or fix \"reference\" in $baseline" >&2
  exit 1
fi

corpus="${MAIL_BRIDGE_BENCH_CORPUS:-}"
if [ -z "$corpus" ]; then
  corpus=$(ls -t "$HOME"/.local/state/mail-bridge/backups/*.sqlite3 2>/dev/null | head -n1 || true)
fi
if [ -z "$corpus" ] || [ ! -f "$corpus" ]; then
  echo "assert-search-benchmark: no corpus (set MAIL_BRIDGE_BENCH_CORPUS)" >&2; exit 1
fi
case "$(readlink -f "$corpus")" in
  "$(readlink -f "$HOME")"/.local/state/mail-bridge/archive.sqlite3)
    echo "assert-search-benchmark: refusing the LIVE archive as a corpus" >&2; exit 1 ;;
esac
for p in "$port" "$((port + 1))"; do
  if ss -ltn 2>/dev/null | grep -q ":$p "; then
    echo "assert-search-benchmark: port $p is already bound" >&2; exit 1
  fi
done

out=$(nix build .#mail-bridge --no-link --print-out-paths)
bin="$out/bin/mail-bridge"

python3 scripts/bench-compare.py \
  --binary "$bin" --corpus "$corpus" --account "$account" --provider "$provider" \
  --port "$port" --runs "$runs" --baseline "$baseline" --reference "$reference"
