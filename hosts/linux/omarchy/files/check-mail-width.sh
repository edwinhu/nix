#!/usr/bin/env bash
# Is the aerc HTML render wide enough, on real mail?
#
# Runs the DEPLOYED filter (whatever aerc.conf currently points at) inside a
# real 126x40 pty, because that is the only faithful instrument: `cha -d` lays
# out at a fixed 80 columns and ignores COLUMNS entirely, so dump-mode widths
# describe a page the pager never draws and report pixels-per-column backwards.
#
# Exit 0 = every fixture inside its bounds. Exit 1 = at least one outside.
# `--report` prints the table and always exits 0.
set -u
REPORT=0
[ "${1:-}" = "--report" ] && REPORT=1

# CHECK_FILTER lets a candidate be measured before it is built into the
# system, so a sweep costs one render each instead of one nix rebuild each.
# Unset -- which is how the gate runs -- it measures what aerc actually uses.
FILTER=${CHECK_FILTER:-$(grep '^text/html=' "$HOME/.config/aerc/aerc.conf" | tail -1 | sed 's/^text\/html=//; s/^!//')}
[ -x "$FILTER" ] || { echo "no deployed text/html filter: $FILTER" >&2; exit 2; }

exec python3 - "$FILTER" "$REPORT" <<'PY'
import email, fcntl, glob, os, pty, re, select, statistics, struct, sys, termios, time

FILTER, REPORT = sys.argv[1], sys.argv[2] == "1"
COLS, ROWS = 126, 40

# fixture -> (matcher, min median width, max median indent)
# Bounds are MEASURED CEILINGS, not aspirations. 110 was picked by hand for
# docket and arcteryx and sat ABOVE what those mails permit: arcteryx lays its
# body out as two 300px columns, which is 75 cells at ppc=4, so 77 is the mail's
# own width and no ratio moves it. The only thing that reached 108 was
# `td{display:block}`, which overflows the viewport and cuts lines off at the
# LEFT edge -- and because clipping RAISES median width, a width-only gate
# scored that as the best candidate and it was deployed before a screenshot
# showed the text was destroyed. These numbers are what the mails actually do
# undamaged.
#
# AND THEY CONFLICT. There is no single ratio that suits both: each mail fixes
# its own container width, so the ratio that fills the pane for one overflows
# it for the other. Measured, median width:
#
#            ppc=4    ppc=5
#   docket .. 106       56
#   arcteryx . 77(!)    94
#
# The (!) is not a win. At ppc=4 arcteryx's 600px container is 150 cells in a
# 126-cell pane; chawan centres it, the offset goes NEGATIVE, and the left of
# every line is cut off -- "Preferred" renders as "eferred". ppc=5 keeps the
# container inside the viewport, so nothing is destroyed and docket is merely
# narrow. These bounds are the no-damage ceilings, and docket's 106 is
# deliberately NOT among them: it was only ever reachable while arcteryx was
# being shredded.
BOUNDS = {
    "dermot":   (("subject", "AI rundown"),   20,  1),
    "readwise": (("subject", "WSJ parser"),   60,  4),
    "docket":   (("subject", "The Docket"),   55,  8),
    "arcteryx": (("from",    "arcteryx"),     90, 10),
}

def fixtures():
    out = {}
    for f in glob.glob(os.path.expanduser("~/areas/mail/*/INBOX/cur/*")):
        if len(out) == len(BOUNDS):
            break
        try:
            m = email.message_from_file(open(f, errors="replace"))
        except Exception:
            continue
        subj, frm = m.get("Subject") or "", (m.get("From") or "").lower()
        for name, ((field, needle), _, _) in BOUNDS.items():
            if name in out:
                continue
            hay = subj if field == "subject" else frm
            if needle.lower() not in hay.lower():
                continue
            for p in m.walk():
                if p.get_content_type() == "text/html":
                    try:
                        h = p.get_payload(decode=True).decode(p.get_content_charset() or "utf-8", "replace")
                    except Exception:
                        continue
                    out[name] = h
                    break
    return out

def render(html):
    """Run the filter the way aerc does: the message on a PIPE at stdin, the
    terminal a separate pty that is also the controlling terminal, so an
    interactive pager can still open /dev/tty for keys. Feeding the document
    into the pty instead makes the document and the keyboard share a channel,
    which measures a render nobody sees."""
    m_fd, s_fd = pty.openpty()
    fcntl.ioctl(s_fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    r_fd, w_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(m_fd); os.close(w_fd)
        os.setsid()
        try:
            fcntl.ioctl(s_fd, termios.TIOCSCTTY, 0)
        except OSError:
            pass
        os.dup2(r_fd, 0); os.dup2(s_fd, 1); os.dup2(s_fd, 2)
        os.close(r_fd)
        if s_fd > 2:
            os.close(s_fd)
        os.environ["TERM"] = "xterm-256color"
        os.execv("/bin/sh", ["/bin/sh", "-c", f'exec "{FILTER}"'])
    os.close(s_fd); os.close(r_fd)
    try:
        os.write(w_fd, html.encode("utf-8", "replace"))
    except OSError:
        pass
    os.close(w_fd)
    # PAGE PAST THE MASTHEAD. A newsletter's first screenful is its logo -- for
    # the Docket that is 9 non-blank rows of [img] and a rule, so measuring
    # screen one measures the header and calls it the body. Let it settle, then
    # page down and sample the screens that actually hold prose.
    buf = b""
    start = time.time()
    end = start + 16
    sent = 0
    # Page down twice once the first paint has settled. The replay below is
    # cumulative, so after the last page-down the grid holds the screen the
    # reader is actually on -- prose, not the logo.
    while time.time() < end:
        r, _, _ = select.select([m_fd], [], [], 0.4)
        elapsed = time.time() - start
        if sent == 0 and elapsed > 4:
            try: os.write(m_fd, b" ")
            except OSError: pass
            sent = 1
        elif sent == 1 and elapsed > 7:
            try: os.write(m_fd, b" ")
            except OSError: pass
            sent = 2
        elif sent == 2 and elapsed > 10:
            sent = 3
        if not r:
            continue
        try:
            chunk = os.read(m_fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
    for sig in (b"q", b"\x03"):
        try:
            os.write(m_fd, sig)
        except OSError:
            pass
    try:
        os.close(m_fd)
    except OSError:
        pass
    try:
        os.kill(pid, 15); os.waitpid(pid, 0)
    except (ProcessLookupError, ChildProcessError):
        pass
    return buf


def screen(buf):
    """Replay the byte stream onto a grid. Escape handling is load-bearing: an
    unconsumed `\x1b[?25h` or an OSC title terminated by ESC-backslash rather
    than BEL lands in the grid AS TEXT, and chawan's title is the file:// URL --
    a 126-column row that silently inflates every width measured here."""
    grid = [[" "] * COLS for _ in range(ROWS)]
    r = c = i = 0
    d = buf.decode("utf-8", "replace")
    while i < len(d):
        ch = d[i]
        if ch == "\x1b":
            m = re.match(r"\x1b\[[0-9;?<>!]*[ -/]*([@-~])", d[i:])
            if m:
                cmd = m.group(1)
                p_ = re.match(r"\x1b\[([0-9;]*)", d[i:]).group(1)
                n = [int(x) if x.isdigit() else 0 for x in p_.split(";")] if p_ else []
                if cmd == "H" or cmd == "f":
                    r = max(0, min(ROWS - 1, (n[0] - 1) if n else 0))
                    c = max(0, min(COLS - 1, (n[1] - 1) if len(n) > 1 else 0))
                elif cmd == "J":
                    grid = [[" "] * COLS for _ in range(ROWS)]
                    if not n or n[0] == 2:
                        r = c = 0
                elif cmd == "K":
                    for x in range(c, COLS):
                        grid[r][x] = " "
                i += m.end()
                continue
            m = re.match(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", d[i:])
            if m:
                i += m.end()
                continue
            m = re.match(r"\x1b[()][0-9A-Za-z]", d[i:])
            if m:
                i += m.end()
                continue
            i += 2
            continue
        if ch == "\n":
            r = min(ROWS - 1, r + 1)
        elif ch == "\r":
            c = 0
        elif ch == "\t":
            c = min(COLS - 1, c + 8)
        elif ord(ch) >= 32:
            if c < COLS:
                grid[r][c] = ch
                c += 1
        i += 1
    return ["".join(row).rstrip() for row in grid]

fx = fixtures()
missing = [k for k in BOUNDS if k not in fx]
if missing:
    print(f"FIXTURES MISSING: {', '.join(missing)} -- cannot judge", file=sys.stderr)
    sys.exit(2)

def vocab(html):
    txt = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", html, flags=re.S | re.I)
    txt = re.sub(r"<[^>]+>", " ", txt)
    txt = re.sub(r"&[a-zA-Z#0-9]+;", " ", txt)
    return {w.lower() for w in re.findall(r"[A-Za-z]{4,}", txt)}

def clipped_fraction(lines, source_vocab):
    """A render that CLIPS is not wide, however wide it measures. A line cut off
    at the left edge starts mid-word -- 'Introducing' arrives as 'ugh',
    'products' as 'ducts' -- so tokens appear that occur nowhere in the source.
    Widening the layout past the viewport RAISES median width while destroying
    the text, so width alone scores that damage as an improvement."""
    seen = orphan = 0
    for l in lines:
        for w in re.findall(r"[A-Za-z]{4,}", l):
            seen += 1
            if w.lower() not in source_vocab:
                orphan += 1
    return (orphan / seen) if seen else 0.0, seen

MAX_CLIP = 0.02

bad = []
print(f"aerc HTML render, {COLS}x{ROWS} pty, filter {os.path.basename(FILTER)}")
for name, (_, min_w, max_i) in BOUNDS.items():
    lines = [l for l in screen(render(fx[name])) if l.strip()]
    if not lines:
        print(f"  {name:9s} EMPTY")
        bad.append(name)
        continue
    w = statistics.median([len(l) for l in lines])
    ind = statistics.median([len(l) - len(l.lstrip()) for l in lines])
    clip, toks = clipped_fraction(lines, vocab(fx[name]))
    # Clipping is REPORTED, not gated: the heuristic flags dermot at 8.6%
    # and docket at 30% on renders that are visibly perfect, because quoted
    # text and entities produce tokens absent from the source. It caught the
    # real arcteryx clipping, so it earns its place as a signal to read --
    # not as a verdict.
    ok = w >= min_w and ind <= max_i
    why = []
    if w < min_w: why.append("narrow")
    if ind > max_i: why.append("indented")
    if clip > MAX_CLIP: why.append("clip? (advisory)")
    print(f"  {name:9s} median_w={w:5.0f} (min {min_w:3d})  median_indent={ind:4.0f} (max {max_i:2d})  "
          f"clipped={clip*100:5.1f}% (max {MAX_CLIP*100:.0f}%)  rows={len(lines):3d}  "
          f"{'ok' if ok else 'OUT OF BOUNDS: ' + ','.join(why)}")
    if not ok:
        bad.append(name)

if REPORT:
    sys.exit(0)
sys.exit(1 if bad else 0)
PY
