#!/usr/bin/env bash
# The --text path renders mail HTML with NO network, and the renderer runs.
#
# An earlier version of this check was VACUOUS and a review caught it: it piped
# HTML containing a remote <img> into the renderer and asserted zero fetches.
# That holds whether or not the renderer is isolated -- chawan only fetches
# remote images for documents that are THEMSELVES remote, and a stdin document
# has no URL at all (modules/shared/chawan-html.nix says so in capitals). The
# assertion could not fail, so it proved nothing.
#
# This version tests the two things that can actually be false:
#   1. the renderer RUNS and produces output (the old `|| true` hid a renderer
#      that never executed, which also reports zero fetches);
#   2. the unshare invocation the wrapper uses genuinely has no network -- shown
#      against a POSITIVE CONTROL that performs the same connection without it
#      and must succeed. Without that control this file would be asserting that
#      a connection fails, which any broken command satisfies.
set -euo pipefail

cd "$(dirname "$0")/.."
fail=0
note() { echo "assert-text-preview-isolated: $*" >&2; fail=1; }

if ! out=$(nix build .#mail-preview --no-link --print-out-paths 2>build.err); then
  note "nix build .#mail-preview failed: $(tail -n2 build.err | tr '\n' ' ')"; rm -f build.err; exit 1
fi
rm -f build.err

script="$out/bin/mail-preview"
cha_html=$(grep -oP 'export CHA_HTML=\K\S+' "$script" | head -n1 || true)
if [ -z "$cha_html" ]; then
  note "the built mail-preview does not export CHA_HTML, so --text has no isolated renderer"
  exit 1
fi
echo "assert-text-preview-isolated: CHA_HTML=$cha_html"

# ---- 1. the renderer actually runs -------------------------------------------
# No `|| true`: a renderer that cannot start must fail this check, not pass it
# by virtue of having fetched nothing.
rendered=$(printf '<html><body><p>sentinel-text-9f2a</p></body></html>' \
  | timeout 60 "$cha_html" 2>render.err) && rc=0 || rc=$?
if [ "${rc:-0}" -ne 0 ]; then
  note "the renderer exited $rc: $(tail -n2 render.err | tr '\n' ' ')"
elif ! grep -q 'sentinel-text-9f2a' <<<"$rendered"; then
  note "the renderer produced no recognisable output: $(head -c 200 <<<"$rendered")"
else
  echo "assert-text-preview-isolated: renderer ran and rendered its input"
fi
rm -f render.err

# ---- 2. the isolation the wrapper applies really removes the network ---------
unshare_cmd=$(grep -oP 'set -- \K\S*/bin/unshare[^"]*?(?= "\$@")' "$cha_html" | head -n1 || true)
if [ -z "$unshare_cmd" ]; then
  note "$cha_html contains no unshare invocation -- the renderer is not network-isolated"
else
  echo "assert-text-preview-isolated: isolation is: $unshare_cmd"

  hits=$(mktemp); trap 'rm -f "$hits"' EXIT
  port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  python3 - "$port" "$hits" <<'PY' &
import socket, sys, threading
port, hits = int(sys.argv[1]), sys.argv[2]
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(8)
while True:
    c, _ = srv.accept()
    open(hits, "a").write("connected\n"); c.close()
PY
  server=$!
  trap 'kill "$server" 2>/dev/null; rm -f "$hits"' EXIT
  sleep 1

  probe='exec 3<>/dev/tcp/127.0.0.1/'"$port"

  # POSITIVE CONTROL: the same connection, no isolation. If this does not
  # register, the detector is broken and the negative result below means nothing.
  bash -c "$probe" >/dev/null 2>&1 || true
  sleep 0.5
  control=$(wc -l < "$hits" 2>/dev/null || echo 0)
  if [ "$control" -lt 1 ]; then
    note "positive control failed: an unisolated connection was not detected, so this check cannot distinguish isolation from a broken probe"
  else
    echo "assert-text-preview-isolated: positive control connected ($control)"
    : > "$hits"
    # NEGATIVE: the wrapper's own isolation must make that same connection fail.
    $unshare_cmd bash -c "$probe" >/dev/null 2>&1 || true
    sleep 0.5
    isolated=$(wc -l < "$hits" 2>/dev/null || echo 0)
    if [ "$isolated" -gt 0 ]; then
      note "the isolated renderer still reached the network ($isolated connection(s))"
    else
      echo "assert-text-preview-isolated: isolated probe reached nothing"
    fi
  fi
  kill "$server" 2>/dev/null || true
fi

[ "$fail" -eq 0 ] || exit 1
echo "assert-text-preview-isolated: ok -- renderer runs, and its isolation blocks a connection the control proves is reachable"
