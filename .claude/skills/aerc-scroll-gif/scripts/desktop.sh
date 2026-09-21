#!/usr/bin/env bash
# Shared desktop plumbing for the aerc-scroll-gif checks. Nothing here focuses a window or uses
# ydotool: keys go to a SPECIFIC window through Hyprland's send_shortcut, and herdr work happens
# in a dedicated named session ("aerc-test") whose client is the fork build in its own ghostty
# window — so a check never touches the user's herdr session or keyboard focus.
# Source it: `. "$(dirname "$(readlink -f "$0")")/desktop.sh"`.

TEST_HERDR_BIN=${TEST_HERDR_BIN:-/home/eh/nix/.craft/herdr-build/bin/herdr}
TEST_SESSION=${TEST_SESSION:-aerc-test}
TEST_CLASS=${TEST_CLASS:-dev.herdr.test}
TEST_SOCKET="$HOME/.config/herdr/sessions/$TEST_SESSION/herdr.sock"

# One desktop check at a time: two of them would interleave keys into each other's windows.
desktop_lock() { exec 9> "${XDG_RUNTIME_DIR:-/tmp}/aerc-scroll-gif.lock"; flock -w 900 9; }

# h: the herdr CLI against the test session (never the user's default session).
h() { "$TEST_HERDR_BIN" --session "$TEST_SESSION" "$@"; }

win_addr_by_class() { hyprctl clients -j | jq -r --arg c "$1" '.[] | select(.class==$c) | .address' | head -1; }
active_win() { hyprctl activewindow -j | jq -r .address; }
# A newly mapped window takes focus on this Hyprland (0.56 refuses window rules via hyprctl), so
# the best a check can do is hand it straight back: call with the address active_win gave BEFORE
# the window was opened.
restore_focus() { [ -n "${1:-}" ] && [ "$1" != "null" ] && hyprctl dispatch "hl.dsp.focus{window='address:$1'}" >/dev/null 2>&1; }
win_geo_by_addr() {  # "WxH+X+Y" in logical pixels, what gpu-screen-recorder -region expects
  hyprctl clients -j | jq -r --arg a "$1" '.[] | select(.address==$a) | "\(.size[0])x\(.size[1])+\(.at[0])+\(.at[1])"'
}

# Ensure the test session's client window exists (fork herdr, own server, own socket). Idempotent.
test_session_ensure() {
  [ -x "$TEST_HERDR_BIN" ] || { echo "desktop.sh: herdr test binary $TEST_HERDR_BIN missing (nix build ~/projects/herdr#default -o /home/eh/nix/.craft/herdr-build)" >&2; return 3; }
  local addr before; addr=$(win_addr_by_class "$TEST_CLASS")
  if [ -z "$addr" ]; then
    before=$(active_win)
    # 9>&-: the window must not inherit the desktop lock fd.
    setsid ghostty --gtk-single-instance=false --class="$TEST_CLASS" --window-width=1258 --window-height=1030 \
      -e env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u HERDR_SESSION -u HERDR_BIN_PATH -u HERDR_CONFIG_PATH \
         "$TEST_HERDR_BIN" --session "$TEST_SESSION" > /dev/null 2>&1 < /dev/null 9>&- &
    for _ in $(seq 80); do addr=$(win_addr_by_class "$TEST_CLASS"); [ -n "$addr" ] && break; sleep 0.25; done
    [ -n "$addr" ] || { echo "desktop.sh: test session window never appeared" >&2; return 3; }
    restore_focus "$before"
    sleep 4
  fi
  for _ in $(seq 20); do [ -S "$TEST_SOCKET" ] && h workspace list >/dev/null 2>&1 && break; sleep 0.5; done
  h workspace list >/dev/null 2>&1 || { echo "desktop.sh: test session API not answering at $TEST_SOCKET" >&2; return 3; }
  TEST_ADDR=$addr
  TEST_WS=$(h workspace list | jq -r '.result.workspaces[0].workspace_id')
  TEST_GEO=$(win_geo_by_addr "$addr")
  export TEST_ADDR TEST_WS TEST_GEO
}

# Keys to a window without focusing it. `key` is an xkb keysym name (Down, Return, space, j,
# semicolon…); mods '' or e.g. 'SHIFT'.
hl_key() { hyprctl dispatch "hl.dsp.send_shortcut{mods='${3:-}', key='$2', window='address:$1'}" >/dev/null; }
hl_hold() {  # window, key, seconds, [hz=25]: a held key as the compositor would repeat it
  local addr=$1 key=$2 secs=$3 hz=${4:-25} n i
  n=$(awk -v s="$secs" -v h="$hz" 'BEGIN{printf "%d", s*h}')
  for ((i = 0; i < n; i++)); do hl_key "$addr" "$key"; sleep "$(awk -v h="$hz" 'BEGIN{printf "%.4f", 1/h}')"; done
}
hl_type() {  # window, text: one send_shortcut per character
  local addr=$1 text=$2 i c
  for ((i = 0; i < ${#text}; i++)); do
    c=${text:i:1}
    case "$c" in
      ' ') hl_key "$addr" space ;;
      ':') hl_key "$addr" semicolon SHIFT ;;
      '-') hl_key "$addr" minus ;;
      '_') hl_key "$addr" minus SHIFT ;;
      '.') hl_key "$addr" period ;;
      '/') hl_key "$addr" slash ;;
      '@') hl_key "$addr" 2 SHIFT ;;
      [A-Z]) hl_key "$addr" "$(tr 'A-Z' 'a-z' <<<"$c")" SHIFT ;;
      *) hl_key "$addr" "$c" ;;
    esac
    sleep 0.02
  done
}
hl_enter() { hl_key "$1" Return; }
