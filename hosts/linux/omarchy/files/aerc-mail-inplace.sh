#!/usr/bin/env bash
# serve $1, then open IN PLACE under a pty so interactiveTty() is true
set -u
[ -r "${1:-}" ] && aerc-mail-serve < "$1" >/dev/null 2>&1
URL=$(sed -n 1p "${XDG_RUNTIME_DIR:-/tmp}/aerc-mail-browser-url" 2>/dev/null)
TB="$HOME/.local/share/terminal-browser/app/bin/terminal-browser"
# script(1) gives the child a real pty: openHere() is gated on interactiveTty()
exec script -qec "$TB open '$URL'" /dev/null
