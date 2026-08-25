#!/usr/bin/env bash
# mail-preview renders HTML to a PNG of the exact width asked for.
#
# Drives the BUILT wrapper, not the source file: the wrapper is what users and
# aerc invoke, and it is what supplies BUN_WEBVIEW_LIB. Exact width is a real
# correctness property -- aerc's herdr-graphics filter CROPS rather than scales,
# so a render even one pixel wide shows a cut edge.
set -euo pipefail

cd "$(dirname "$0")/.."
width="${MAIL_PREVIEW_TEST_WIDTH:-640}"
fail=0
note() { echo "assert-mail-preview: $*" >&2; fail=1; }

if [ -e hosts/linux/omarchy/files/mail-preview.py ]; then
  note "mail-preview.py still exists; the port replaces it"
fi

# Same reason as assert-webview-package.sh: a missing attribute is a finding to
# report, not an error to die on.
if ! out=$(nix build .#mail-preview --no-link --print-out-paths 2>build.err); then
  note "nix build .#mail-preview failed: $(tail -n2 build.err | tr '\n' ' ')"
  rm -f build.err
  exit 1
fi
rm -f build.err
bin="$out/bin/mail-preview"
[ -x "$bin" ] || { note "no executable at $bin"; exit 1; }

html='<h1 style="font-family:sans-serif">Fixture heading</h1><p>body text</p>'
png=$(printf '%s' "$html" | MAIL_PREVIEW_WIDTH="$width" "$bin" --html | tail -n1)

if [ -z "$png" ] || [ ! -f "$png" ]; then
  note "no PNG path on stdout (got '${png:-<empty>}')"
else
  read -r got_w got_h < <(python3 - "$png" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read(24)
if data[:8] != b"\x89PNG\r\n\x1a\n":
    print("0 0"); raise SystemExit
w, h = struct.unpack(">II", data[16:24])
print(w, h)
PY
)
  echo "assert-mail-preview: $png is ${got_w}x${got_h}, requested width $width"
  [ "$got_w" = "$width" ] || note "PNG width $got_w != requested $width"
  [ "${got_h:-0}" -gt 0 ] || note "PNG height is zero"
fi

[ "$fail" -eq 0 ] || exit 1
echo "assert-mail-preview: ok -- ${got_w}x${got_h} PNG at $png"
