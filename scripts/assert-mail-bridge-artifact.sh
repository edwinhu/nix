#!/usr/bin/env bash
# The compiled artifact is sound, and the 1.3.14-era workaround is gone.
#
# Three facts. The first is the only one that is real evidence:
#   1. the binary STARTS and answers `archive doctor`. The failure this guards
#      -- a 190 MB output that the bundler reports as success and that segfaults
#      on every argv -- is invisible to any check that only reads the file.
#   2. bun-pinned.nix no longer carries the pristine template;
#   3. mail-bridge.nix no longer passes --compile-executable-path.
#
# 2 and 3 are source greps because a retired workaround leaves no trace in the
# artifact: under bun 1.4 BOTH templates produce a working 82.5 MB binary, and
# the only difference is which ELF interpreter is inherited. That is exactly why
# there is no interpreter assertion here -- the interpreter identifies the
# template, not the health of the binary, and asserting either value would be a
# proxy that passes while the binary is broken.
set -euo pipefail

cd "$(dirname "$0")/.."
fail=0
note() { echo "assert-mail-bridge-artifact: $*" >&2; fail=1; }

out=$(nix build .#mail-bridge --no-link --print-out-paths)
bin="$out/bin/mail-bridge"

if ! "$bin" archive doctor >/dev/null 2>&1; then
  note "the artifact could not run \`archive doctor\`"
fi

size=$(stat -c%s "$bin")
if [ "$size" -gt 150000000 ]; then
  note "artifact is $size bytes -- the corrupt output is ~190 MB, a sound one ~82 MB"
fi

if grep -Eq 'pristine[[:space:]]*=|inherit[^;]*pristine' modules/shared/bun-pinned.nix; then
  note "bun-pinned.nix still carries the pristine template"
fi

if grep -q -- '--compile-executable-path=' modules/shared/mail-bridge.nix; then
  note "mail-bridge.nix still passes --compile-executable-path"
fi

floor=$(grep -oP 'bunFloor = "\K[^"]+' modules/shared/mail-bridge.nix | head -n1)
if [ "$floor" != "1.4.0" ]; then
  note "bunFloor is '$floor', expected 1.4.0 -- below 1.4 the default template is corrupt"
fi

[ "$fail" -eq 0 ] || exit 1
echo "assert-mail-bridge-artifact: ok -- doctor ran, $size bytes, floor $floor, workaround retired"
