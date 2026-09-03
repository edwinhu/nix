"""Print the terminal's cell size in pixels, as "<width> <height>".

Getting this wrong scales every inline image: a guessed 36px cell height against
a real ~45 draws a mail's hero image ~24% too tall, which a side-by-side against
Chromium makes obvious.

TIOCGWINSZ is not the source here. aerc's pixel-geometry patch populates vaxis's
terminal MODEL, not the child pty's winsize, so the ioctl reports zeros. But
vaxis answers XTWINOPS out of that same model, so asking the terminal works:
CSI 16 t replies CSI 6 ; height ; width t with the cell size it draws at.

Prints nothing when the terminal does not answer; the caller keeps its default.
"""
import os
import re
import select
import sys
import termios
import tty

try:
    fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
except OSError:
    sys.exit(0)

buf = b""
try:
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)
    try:
        os.write(fd, b"\x1b[16t")
        # The reply is short and ends at 't'. Bail on the first quiet moment so a
        # terminal that never answers costs one timeout, not the whole budget.
        while len(buf) < 32:
            if not select.select([fd], [], [], 0.4)[0]:
                break
            c = os.read(fd, 1)
            if not c or c == b"t":
                buf += c
                break
            buf += c
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, saved)
except (termios.error, OSError):
    sys.exit(0)
finally:
    os.close(fd)

m = re.search(rb"\x1b\[6;(\d+);(\d+)t", buf)
if m:
    height, width = int(m.group(1)), int(m.group(2))
    # Reject nonsense rather than scale every image by it.
    if 4 <= width <= 100 and 4 <= height <= 200:
        print(width, height)
