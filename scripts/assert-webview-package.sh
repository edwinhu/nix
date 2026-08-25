#!/usr/bin/env bash
# The helper is installed by nix and usable from the store path.
#
# Importing from an UNRELATED cwd is the point: the consumers are scripts that
# run from anywhere, resolving the library through BUN_WEBVIEW_LIB. An import
# that only works from inside the repo would pass a weaker check and fail in use.
set -euo pipefail

cd "$(dirname "$0")/.."
repo=$PWD
# shellcheck source=scripts/lib-pinned-bun.sh
. scripts/lib-pinned-bun.sh
bun=$(pinned_bun)

fail=0
note() { echo "assert-webview-package: $*" >&2; fail=1; }

# Capture rather than inherit `set -e`: a missing flake attribute is this
# check's FINDING, and a probe that dies mid-command prints nothing a gate can
# read and is classified could-not-run rather than red.
if ! out=$(nix build .#bun-webview --no-link --print-out-paths 2>build.err); then
  note "nix build .#bun-webview failed: $(tail -n2 build.err | tr '\n' ' ')"
  rm -f build.err
  exit 1
fi
rm -f build.err
lib="$out/lib/bun-webview"

[ -f "$lib/index.ts" ]    || note "no index.ts at $lib"
[ -f "$lib/package.json" ] || note "no package.json at $lib"
# The test suite is repo-only; shipping it would drag bun:test into the closure.
[ -e "$lib/index.test.ts" ] && note "index.test.ts was installed; it should not be"

if [ "$fail" -eq 0 ]; then
  probe=$(mktemp -d); trap 'rm -rf "$probe"' EXIT
  cat > "$probe/probe.ts" <<PROBE
const { resolveChromium } = await import("$lib/index.ts");
const path = resolveChromium();
if (!path) throw new Error("resolveChromium returned nothing");
console.log("resolved " + path);
PROBE
  # Run from the temp dir, not the repo: nothing may resolve by relative path.
  ( cd "$probe" && "$bun" "$probe/probe.ts" ) || note "the installed library could not be imported and used from an unrelated cwd"
fi

cd "$repo"
[ "$fail" -eq 0 ] || exit 1
echo "assert-webview-package: ok -- $lib imports and resolves chromium from an unrelated cwd"
