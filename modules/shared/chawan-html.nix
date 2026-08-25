# Network-isolated Chawan text renderer, used by `mail-preview --text` from both
# call sites that ship it: the omarchy host module and the standalone
# packages.<system>.mail-preview in flake.nix. Mail HTML is attacker-controlled,
# so both must get the isolation — one definition, not two copies of the flags.
#
# chawan (not w3m) because it has a real CSS engine and honours a newsletter's
# own column layout instead of flattening it — measured 29ms vs w3m's 21ms on a
# 142KB newsletter, so the fidelity is nearly free. Dump mode renders exactly
# the same as the interactive mode did; it is the SAME renderer, so nothing
# about the layout changes.
#
# INLINE IMAGES ARE IMPOSSIBLE THROUGH THIS CHAWAN PATH. aerc pipes the
# message part in on STDIN, so chawan treats the
# document as `<*stdin*>` — and chawan only fetches remote images for documents
# that are THEMSELVES remote. Every image in an email is a remote URL, so none
# of them ever load. Measured three ways: an https document loaded 52/56
# images, the same markup as a file:// document loaded 0/1, and via stdin
# (aerc's actual path) every image rendered as `[img]`. There is no config to
# relax it — `buffer.images` is only on/off, and siteconf matches on URL, which
# a stdin document has none of. Interactive mode, forced image-mode, and
# hardcoded cell geometry were each tried and none of them address this.
#
# Consequences of dump mode, all of them wins given the above:
#   - aerc's own keybindings work; chawan no longer owns input until `q`.
#   - Scrolling is aerc's pager, so no chawan key rebinding is needed. (The
#     interactive version had to remap j/k/arrows/space because chawan's own
#     scroll keys — J/K, C-e/C-y — are all swallowed by aerc's [view] binds.)
#   - `unshare --net` is back, which is what blocks tracking pixels. It also
#     keeps chawan fast: with network access it tries to fetch remote images
#     and fonts and hangs for minutes on a real newsletter.
#
# -I/-O UTF-8 are NOT optional; dropping them is what produced mojibake
# (a curly apostrophe rendering as "â€™"). aerc decodes a part to UTF-8
# before piping it here, but plenty of marketing mail carries a <meta> that
# still DECLARES a legacy charset, and chawan believes the declaration over
# the bytes — decoding UTF-8 as windows-1252. Reproduced exactly: a page
# declaring windows-1252 while holding UTF-8 bytes came out as the byte
# sequence C3 A2 E2 82 AC E2 84 A2. aerc's own shipped w3m filter passes both
# flags for precisely this reason; this filter replaced it and initially did
# not.
#
# STYLING AND WIDTH MUST BE FORCED IN DUMP MODE, or the output is plain
# monochrome text wrapped at 80 columns — every style chawan's CSS engine
# computed is thrown away on the way out. `-d` writes to a pipe, so chawan
# cannot detect the terminal and its "auto" settings resolve to nothing:
#   - color-mode        → monochrome. Measured: 0 escape sequences in the
#                         output; with true-color, 1632.
#   - format-mode       → no attributes. color-mode alone is NOT enough —
#                         with only colour forced, bold/italic/underline are
#                         all still absent; this array is what restores them.
#   - columns           → the documented 80 fallback, while the message view
#                         is ~130 wide, so everything was squeezed into 80
#                         columns with heavy padding.
# 120 leaves margin inside a 152-column terminal minus aerc's 22-column
# sidebar. aerc's pager (`less -Rc`) passes the escapes through.
#
# stdin: aerc pipes the part in, so chawan reads `-`. chawan BLOCKS on an open
# stdin it has not been told to read, so the `-` is load-bearing.
{ writeShellScript, chawan, util-linux }:

writeShellScript "chawan-html" ''
  set -u
  set -- ${chawan}/bin/cha -d -T text/html -I UTF-8 -O UTF-8 \
    -o 'display.color-mode="true-color"' \
    -o 'display.format-mode=["bold","italic","underline","reverse","strike"]' \
    -o 'display.columns=120' \
    -o 'display.force-columns=true' \
    -
  if command -v ${util-linux}/bin/unshare >/dev/null 2>&1; then
    set -- ${util-linux}/bin/unshare --map-root-user --net "$@"
  fi
  exec "$@"
''
