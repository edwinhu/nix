#!/usr/bin/env bash
# `o` on an open message: the mail as a PICTURE, in aerc's own pane.
#
# aerc's embedded terminal renders SIXEL -- measured, a 400x300 img2sixel block
# drew inside `:term`. It drops kitty graphics, which is why terminal-browser
# can never paint here and needed a split. Nothing splits, nothing opens a new
# window.
#
# Run under `:term`, so this gets a real terminal to draw into. It prints an
# image and waits for a key; it never repaints, which is what made the old
# interactive-browser filter overdraw the message view.
set -u
export PATH=/run/current-system/sw/bin:/usr/bin:/bin:$PATH
MSG=${1:-}

die(){ printf '%s\n\npress q to close\n' "$1"; read -r -n 1 _; exit 1; }
[ -r "$MSG" ] || die "no message file"

MP=$(ls -t /nix/store/*-mail-preview/bin/mail-preview 2>/dev/null | head -1)
I2S=$(ls -t /nix/store/*libsixel*/bin/img2sixel 2>/dev/null | head -1)
MAGICK=$(ls -t /nix/store/*imagemagick*/bin/magick 2>/dev/null | head -1)
[ -x "$MP" ] && [ -x "$I2S" ] && [ -x "$MAGICK" ] || die "renderer missing"

# The HTML part, or the plain one if the mail has no HTML.
HTML=$(python3 - "$MSG" <<'PY'
import email, email.policy, sys
m = email.message_from_file(open(sys.argv[1], errors="replace"), policy=email.policy.default)
p = m.get_body(preferencelist=("html",)) or m.get_body(preferencelist=("plain",))
c = p.get_content() if p else ""
sys.stdout.write(c if p and p.get_content_type() == "text/html"
                 else "<pre>" + c.replace("&", "&amp;").replace("<", "&lt;") + "</pre>")
PY
)
[ -n "$HTML" ] || die "no body to render"

printf 'rendering...\r'
PNG=$(printf '%s' "$HTML" | "$MP" --html --render-only 2>/dev/null | tail -1)
[ -n "$PNG" ] && [ -f "$PNG" ] || die "the renderer produced no image"

# Size to the terminal we were given. tput reads the real pty, unlike COLUMNS,
# which aerc does not export into a :term child.
COLS=$(tput cols 2>/dev/null || echo 80)
ROWS=$(tput lines 2>/dev/null || echo 24)
CW=${AERC_CELL_W:-16}; CH=${AERC_CELL_H:-36}
W=$(( (COLS - 1) * CW ))
# Two rows spare, and the prompt is printed WITHOUT a leading newline. An
# image sized to the full pane plus a "\n[q] close" line is one row too tall,
# so the terminal scrolls and the bottom line of the mail disappears behind
# the prompt.
H=$(( (ROWS - 4) * CH ))
[ "$W" -gt 50 ] && [ "$H" -gt 50 ] || die "pane too small"

printf '\033[2J\033[H'
# Scale to width and show the top; scrolling a sixel is not a thing, so the
# rest of the mail stays in the text view behind this.
"$MAGICK" "$PNG" -resize "${W}x" -background white -flatten \
    -crop "${W}x${H}+0+0" +repage png:- 2>/dev/null | "$I2S" 2>/dev/null

printf '[q] close'
read -r -n 1 _
