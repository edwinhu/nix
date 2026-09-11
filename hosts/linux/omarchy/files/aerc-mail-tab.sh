#!/usr/bin/env bash
# Open the served mail FULL-WINDOW in the same herdr window: a new TAB, not a
# split, not a new OS window.
#
# Why not aerc's own pane, which is what was asked for: aerc's embedded
# terminal does not implement the kitty graphics protocol. Measured -- a
# kitty-graphics image emitted inside `:term` printed its caption and no
# image. So no graphical renderer can ever paint there; the split only works
# because terminal-browser gets a herdr pane and HERDR composites it. A tab is
# the closest thing that is still one window and still full width.
#
# `q` in terminal-browser exits, and the tab closes itself, so the window is
# back on aerc with nothing left holding a pane.
set -u
PATH=/run/current-system/sw/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH

URL=$(sed -n 1p "${XDG_RUNTIME_DIR:-/tmp}/aerc-mail-browser-url" 2>/dev/null)
TB="$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
[ -n "$URL" ] && [ -x "$TB" ] || exit 1

# The workspace is the prefix of our own pane id: w19:p2E -> w19. Pane ids
# change across a herdr restart, so nothing here may be hard-coded.
WS=${HERDR_PANE_ID%%:*}
[ -n "$WS" ] || exit 1

NEW=$(herdr tab create --workspace "$WS" --label mail --focus 2>/dev/null \
      | grep -v '^mise' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"]["tab"]["tab_id"])' 2>/dev/null)
[ -n "$NEW" ] || exit 1

PANE=$(herdr pane list 2>/dev/null | grep -v '^mise' \
       | python3 -c "import json,sys; print(next(p['pane_id'] for p in json.load(sys.stdin)['result']['panes'] if p['tab_id']=='$NEW'))" 2>/dev/null)
[ -n "$PANE" ] || exit 1

KEYS=$(ls -t /nix/store/*-aerc-pager-keys.js 2>/dev/null | head -1)
herdr pane send-text "$PANE" "clear; '$TB' open '$URL' ${KEYS:+--preload=$KEYS} --app-mode --no-toolbar --no-frame --no-overlays --no-context-menu; herdr tab close $NEW" >/dev/null
herdr pane send-keys "$PANE" enter >/dev/null
