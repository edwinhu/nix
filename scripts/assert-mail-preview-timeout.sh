#!/usr/bin/env bash
# A wedged himalaya must not hang the preview, and the bound must be the one
# configured rather than a coincidence.
#
# An earlier version of this check was VACUOUS and a review caught it: it
# asserted only that the process exited non-zero, quickly, and was not killed by
# the outer `timeout`. ANY early failure satisfied that -- a parse error before
# himalaya was ever spawned would have passed it -- and it never set the
# override it was supposed to be exercising, so the env var shipped untested.
#
# What it does now: run twice with two DIFFERENT timeouts and require the
# measured wait to track each one. A hard-coded bound cannot produce two
# different elapsed times, and a script that dies before spawning cannot produce
# either.
#
# Driven against the SCRIPT rather than the packaged wrapper on purpose: the
# wrapper prepends its runtimeInputs to PATH, so a shim would never be reached.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib-pinned-bun.sh
. scripts/lib-pinned-bun.sh
bun=$(pinned_bun)

lib=$(nix build .#bun-webview --no-link --print-out-paths 2>/dev/null)/lib/bun-webview
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
printf '#!/usr/bin/env bash\nsleep 600\n' > "$work/bin/himalaya"
chmod +x "$work/bin/himalaya"

fail=0
note() { echo "assert-mail-preview-timeout: $*" >&2; fail=1; }

# Echoes the whole-seconds wait for a given configured timeout, or "KILLED".
run_with() {
  local ms=$1 started elapsed rc
  started=$(date +%s)
  set +e
  PATH="$work/bin:$PATH" BUN_WEBVIEW_LIB="$lib" \
    MAIL_PREVIEW_HIMALAYA_TIMEOUT_MS="$ms" \
    timeout 90 "$bun" hosts/linux/omarchy/files/mail-preview.ts -a work 1 \
    >"$work/out.$ms" 2>"$work/err.$ms"
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 124 ] && { echo "KILLED"; return; }
  [ "$rc" -eq 0 ] && { echo "EXIT0"; return; }
  echo "$elapsed"
}

short=$(run_with 3000)
long=$(run_with 12000)
echo "assert-mail-preview-timeout: 3000ms -> ${short}s, 12000ms -> ${long}s"

for r in "$short" "$long"; do
  [ "$r" = "KILLED" ] && note "never gave up on a hanging himalaya"
  [ "$r" = "EXIT0" ] && note "reported success against a himalaya that returned nothing"
done

if [ "$fail" -eq 0 ]; then
  # It actually WAITED, rather than dying instantly for some other reason.
  [ "$short" -ge 2 ] || note "gave up after ${short}s with a 3000ms bound -- it did not wait for the timeout, so something else failed first"
  # The configured value is what decides, so the two runs must differ.
  [ "$long" -gt "$short" ] || note "12000ms did not wait longer than 3000ms (${long}s vs ${short}s) -- the override is not being honoured"
  [ "$long" -ge 10 ] || note "a 12000ms bound gave up after only ${long}s"
  # And it says why.
  grep -qiE 'did not respond|timed out|timeout' "$work/err.3000" \
    || note "stderr does not report a timeout: $(head -c 200 "$work/err.3000")"
  grep -q 'himalaya' "$work/err.3000" || note "stderr does not name himalaya"
fi

[ "$fail" -eq 0 ] || exit 1
echo "assert-mail-preview-timeout: ok -- the wait tracks the configured bound and is reported as a timeout"
