#!/usr/bin/env bash
# mail-preview must run the himalaya that accepts the flags it passes.
#
# The script invokes `himalaya message read --raw -a ACC -m BOX ID`. The user's
# himalaya is the pinned 2.1.0 from modules/shared/himalaya-release.nix, which
# accepts that. The wrapper's runtimeInputs list nixpkgs' himalaya instead, and
# writeShellApplication PREPENDS runtimeInputs to PATH, so the packaged
# mail-preview resolves the wrong one and every `-a/-m` invocation dies with
#   error: unexpected argument '--raw' found
# This predates the TypeScript port -- the wrapper at HEAD had the same list --
# but it means the account path has never worked from the package.
set -euo pipefail

cd "$(dirname "$0")/.."
fail=0
note() { echo "assert-mail-preview-himalaya: $*" >&2; fail=1; }

if ! out=$(nix build .#mail-preview --no-link --print-out-paths 2>build.err); then
  note "nix build .#mail-preview failed: $(tail -n2 build.err | tr '\n' ' ')"; rm -f build.err; exit 1
fi
rm -f build.err
bin="$out/bin/mail-preview"

# The PATH the wrapper actually builds for itself, taken from the script rather
# than guessed.
wrapper_path=$(grep -oP "^export PATH=\"?\K[^\"]+" "$bin" | head -n1 || true)
if [ -z "$wrapper_path" ]; then
  note "could not read the wrapper's PATH out of $bin"
  exit 1
fi

hima=$(PATH="$wrapper_path" command -v himalaya || true)
if [ -z "$hima" ]; then
  note "no himalaya on the wrapper's own PATH"
else
  echo "assert-mail-preview-himalaya: wrapper resolves $hima ($("$hima" --version 2>&1 | head -1))"
  # The decisive check: does THAT himalaya accept the exact flag the script
  # passes, in the position it passes it?
  if ! "$hima" message read --raw --help >/dev/null 2>&1; then
    note "$hima rejects 'message read --raw' -- every -a/-m preview will fail"
  else
    echo "assert-mail-preview-himalaya: it accepts 'message read --raw'"
  fi
fi

[ "$fail" -eq 0 ] || exit 1
echo "assert-mail-preview-himalaya: ok -- the packaged himalaya accepts the flags mail-preview passes"
