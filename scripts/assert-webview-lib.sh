#!/usr/bin/env bash
# The bun-webview helper does what its test suite says.
#
# The suite drives a REAL headless Chromium against a loopback fixture server.
# A stubbed browser would prove nothing here: the whole question is whether
# Bun.WebView does what CDP did.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib-pinned-bun.sh
. scripts/lib-pinned-bun.sh

bun=$(pinned_bun)
if [ -z "$bun" ] || [ ! -x "$bun" ]; then
  echo "assert-webview-lib: no bun found (set BUN=/path/to/bun)" >&2; exit 1
fi
echo "assert-webview-lib: bun $("$bun" --revision 2>/dev/null || echo unknown) at $bun"

if ! command -v chromium >/dev/null 2>&1 \
  && ! command -v chromium-browser >/dev/null 2>&1 \
  && ! command -v google-chrome-stable >/dev/null 2>&1 \
  && ! command -v chrome >/dev/null 2>&1; then
  echo "assert-webview-lib: no chromium on PATH -- the browser tests cannot run" >&2
  exit 1
fi

"$bun" test modules/shared/bun-webview/
