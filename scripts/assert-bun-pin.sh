#!/usr/bin/env bash
# The pinned bun landed AND mail-bridge embedded it.
#
# `bun build --compile` bakes the runtime into the artifact, so the only proof
# that matters is the version stamped inside the produced binary -- not the
# version string in the .nix file, which a silently-ignored override would leave
# looking correct.
set -euo pipefail

expected="${1:-1.4.0}"
cd "$(dirname "$0")/.."

out=$(nix build .#mail-bridge --no-link --print-out-paths)
bin="$out/bin/mail-bridge"

embedded=$(grep -a -o -m1 -E 'Bun/[0-9]+\.[0-9]+\.[0-9]+' "$bin" | head -n1)
if [ "$embedded" != "Bun/$expected" ]; then
  echo "assert-bun-pin: embedded runtime $embedded, expected Bun/$expected" >&2
  exit 1
fi

pinned=$(nix eval --raw .#mail-bridge.drvPath >/dev/null 2>&1; grep -oP '^\s*version = "\K[^"]+' modules/shared/bun-pinned.nix | head -n1)
if [ "$pinned" != "$expected" ]; then
  echo "assert-bun-pin: bun-pinned.nix pins $pinned, expected $expected" >&2
  exit 1
fi

echo "assert-bun-pin: ok -- $embedded, pin $pinned"
