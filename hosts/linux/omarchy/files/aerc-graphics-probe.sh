#!/usr/bin/env bash
# Does aerc's embedded terminal RELAY a child process's kitty graphics escapes,
# or parse and discard them? This MEASURES that; it does not fix it.
#
# A disposable XDG_CONFIG_HOME and maildir hold one text/html message whose
# text/html filter writes a FIXED, hand-written kitty APC chunk to stdout. No
# chawan, no image fetch, no mode detection, and pager=cat -- so nothing between
# the filter and aerc's terminal can eat the bytes, and a zero can only mean
# aerc itself dropped them. A real aerc then runs on a real pty whose master
# side is captured byte for byte, and the marked APC chunks in it are counted.
#
# Prints exactly one line, apc_chunks=<N>, and exits 0. N>0 means aerc relays a
# child's graphics; N==0 means it does not. Both are successful measurements.
# Any exit other than 0 means the measurement could not be trusted, not that the
# answer is zero.
set -u

command -v aerc    >/dev/null 2>&1 || { echo "aerc not on PATH" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not on PATH" >&2; exit 2; }

# Every artifact of this run lives under one 0700 directory: a synthetic
# accounts.conf, maildir and message body must never touch the user's own.
root=$(mktemp -d "${TMPDIR:-/tmp}/aerc-gfx-probe.XXXXXXXX") || exit 2
chmod 700 "$root"

cleanup() {
  local pid
  # Kill only aercs whose environment names THIS run's root. Never by bare name,
  # which would take out the user's own aerc.
  for pid in $(pgrep -x aerc 2>/dev/null); do
    if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qF "$root"; then
      kill -9 "$pid" 2>/dev/null
    fi
  done
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

cfg=$root/config/aerc
mail=$root/mail
mkdir -p "$cfg" "$root/bin" "$mail/INBOX/cur" "$mail/INBOX/new" "$mail/INBOX/tmp"

# The known payload: one kitty transmit-and-display chunk for a 1x1 red pixel,
# tagged with image id 24601 so it can be told apart from the capability query
# (ESC _ G i=1,a=q ESC \) aerc's own Vaxis layer emits at startup. Counting bare
# ESC_G would score that query and measure nothing.
cat > "$root/bin/apc-filter.sh" <<'FILTER'
#!/usr/bin/env bash
cat >/dev/null                      # aerc pipes the part in; the body is irrelevant
printf 'ran\n' > "$PROBE_MARKER"    # proof the filter executed, independent of
                                    # anything aerc later chooses to draw
printf 'PROBE-FILTER-RAN\n'
printf '\033_Gf=24,s=1,v=1,a=T,i=24601,m=0;/wAA\033\\'
printf '\nPROBE-FILTER-DONE\n'
FILTER
chmod 700 "$root/bin/apc-filter.sh"

# One counter, used for both the control and the measurement, so the control
# really does exercise the code that produces the reported number.
count_apc() { # $1 = capture file
  python3 -c '
import re, sys
blob = open(sys.argv[1], "rb").read()
chunks = re.findall(rb"\x1b_G.*?\x1b\\", blob, re.S)
# Score only chunks carrying one of the filter payload'"'"'s marks. Matching the
# marks rather than the exact byte string still scores a chunk the terminal
# re-serialised on the way through; aerc'"'"'s own i=1,a=q query carries neither.
print(sum(1 for c in chunks if b"i=24601" in c or b";/wAA" in c))
' "$1"
}

# --- positive control --------------------------------------------------------
# Run the very same filter on a plain pty and count with the very same counter.
# A pty that relays must score >0. If it does not, the capture or the counter is
# broken and any zero from the aerc run would be meaningless -- so fail loudly
# rather than report a number that measures the harness instead of aerc.
control_cap=$root/control.bin
PROBE_MARKER=$root/control-ran \
timeout 30 python3 - "$control_cap" "$root/bin/apc-filter.sh" <<'PY'
import os, pty, subprocess, sys

capture, cmd = sys.argv[1], sys.argv[2]
master, slave = pty.openpty()
# stdin from /dev/null: the filter drains its part and must see EOF, which a pty
# would never deliver. stdout is the pty -- the channel under test.
with open(os.devnull, "rb") as devnull:
    proc = subprocess.Popen([cmd], stdin=devnull, stdout=slave, stderr=slave)
os.close(slave)
with open(capture, "wb") as out:
    while True:
        try:
            data = os.read(master, 65536)
        except OSError:
            break
        if not data:
            break
        out.write(data)
os.close(master)
proc.wait(timeout=10)
PY
control_n=$(count_apc "$control_cap") || { echo "counting failed (control)" >&2; exit 2; }
if [ "${control_n:-0}" -lt 1 ]; then
  echo "positive control saw $control_n APC chunks on a plain pty: the capture or" >&2
  echo "counter cannot observe the payload, so no measurement is possible" >&2
  exit 2
fi

# --- the message, the account, the filter registration -----------------------

cat > "$cfg/accounts.conf" <<EOF
[probe]
source = maildir://$mail
outgoing = /bin/true
default = INBOX
from = Probe <probe@example.invalid>
EOF
chmod 600 "$cfg/accounts.conf"   # aerc refuses to start on anything laxer

# pager=cat is load-bearing: aerc pipes filter output THROUGH the pager into its
# built-in terminal, and the default `less -Rc` would swallow the APC itself.
cat > "$cfg/aerc.conf" <<EOF
[general]
log-file=$root/aerc.log

[ui]
mouse-enabled=false

[viewer]
pager=cat
alternatives=text/html,text/plain

[filters]
text/html=$root/bin/apc-filter.sh
EOF
chmod 600 "$cfg/aerc.conf"

msg="$mail/INBOX/cur/1704067200.probe.fixture:2,S"
cat > "$msg" <<'EOF'
From: Sender <sender@example.invalid>
To: Probe <probe@example.invalid>
Subject: PROBEMSG
Date: Mon, 01 Jan 2024 00:00:00 +0000
Message-ID: <probe-fixture@example.invalid>
MIME-Version: 1.0
Content-Type: text/html; charset=utf-8

<html><body><p>probe body</p></body></html>
EOF
chmod 600 "$msg"

marker=$root/filter-ran
[ -e "$marker" ] && { echo "stale filter marker" >&2; exit 2; }

capture=$root/capture.bin
keys=$root/keys.fifo
mkfifo -m 600 "$keys" || exit 2

# aerc runs on a pty master drained byte for byte. Keystrokes arrive through the
# fifo; the feeder writes each one only once the state it depends on is
# observable (the subject drawn, the filter's marker created, the output gone
# quiet) -- never on a fixed sleep. Every wait is bounded, so a hung aerc cannot
# wedge the caller.
XDG_CONFIG_HOME=$root/config \
XDG_DATA_HOME=$root/data \
XDG_CACHE_HOME=$root/cache \
XDG_STATE_HOME=$root/state \
HOME=$root \
TERM=xterm-kitty \
PROBE_MARKER=$marker \
AERC_GFX_PROBE_ROOT=$root \
python3 - "$capture" "$keys" "$marker" <<'PY'
import errno, fcntl, os, pty, re, select, signal, struct, sys, termios, time

capture, keys_path, filter_marker = sys.argv[1], sys.argv[2], sys.argv[3]

DEADLINE    = 45.0   # hard bound on the whole session
BOOT_WAIT   = 20.0   # for the message list to draw
FILTER_WAIT = 20.0   # for the text/html filter to execute
QUIET_FOR   = 1.0    # output must be idle this long before we call it settled
SETTLE_WAIT = 8.0    # bound on that idleness
EXIT_WAIT   = 8.0    # bound on aerc exiting after :quit

# Keys are written into the fifo and read back out here, then forwarded to the
# pty. Holding the write end open O_RDWR is what keeps the reader from seeing
# EOF between keystrokes.
keys_w = os.open(keys_path, os.O_RDWR | os.O_NONBLOCK)
keys_r = os.open(keys_path, os.O_RDONLY | os.O_NONBLOCK)

pid, fd = pty.fork()
if pid == 0:
    # os._exit, not a raised exception: a child that fell through to the parent's
    # code would write the capture file and report a fabricated measurement.
    try:
        os.execvp("aerc", ["aerc"])
    finally:
        os._exit(127)

# Pixel dimensions must be NONZERO. With xpixel/ypixel 0 Vaxis has no cell
# geometry and silently degrades to its half-block renderer, so a graphics count
# would measure the harness rather than aerc.
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 140, 1680, 900))

out = open(capture, "wb")
seen = bytearray()
start = time.monotonic()
last_output = start
reaped = False


def elapsed():
    return time.monotonic() - start


def alive():
    global reaped
    if reaped:
        return False
    try:
        done, _ = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        reaped = True
        return False
    if done == pid:
        reaped = True
        return False
    return True


# --- terminal-capability responder -------------------------------------------
# Vaxis asks the HOST terminal what it supports before it will emit graphics. On
# a bare pty master nothing answers, Vaxis concludes "no kitty graphics" -- and
# then a count of zero would measure THIS HARNESS, not aerc. So the relay answers
# as a kitty-capable terminal would. kitty_query_answered is a precondition of
# the measurement: without it the number below says nothing about aerc.
kitty_query_answered = False
answered = []

_QUERIES = [
    # (pattern, reply builder). The kitty entry matches only a=q -- an APC that
    # aerc RELAYED carries a=T, and answering that would corrupt the count.
    (re.compile(rb"\x1b_G(?=[^\x1b]*a=q)[^\x1b]*i=(\d+)[^\x1b]*\x1b\\"),
     lambda m: b"\x1b_Gi=" + m.group(1) + b";OK\x1b\\"),          # kitty graphics: supported
    (re.compile(rb"\x1bP\+q([0-9A-Fa-f;]+)\x1b\\"),
     lambda m: b"\x1bP0+q" + m.group(1) + b"\x1b\\"),             # XTGETTCAP: unknown
    (re.compile(rb"\x1b\[\?(\d+);\d+;\d+S"),
     lambda m: b"\x1b[?" + m.group(1) + b";0;1680;900S"),         # XTSMGRAPHICS
    (re.compile(rb"\x1b\[14t"), lambda m: b"\x1b[4;900;1680t"),  # window size, pixels
    (re.compile(rb"\x1b\[18t"), lambda m: b"\x1b[8;45;140t"),    # text area, cells
    (re.compile(rb"\x1b\]10;\?(?:\x07|\x1b\\)"),
     lambda m: b"\x1b]10;rgb:ffff/ffff/ffff\x07"),                # fg colour
    (re.compile(rb"\x1b\]11;\?(?:\x07|\x1b\\)"),
     lambda m: b"\x1b]11;rgb:0000/0000/0000\x07"),                # bg colour
    (re.compile(rb"\x1b\]4;(\d+);\?(?:\x07|\x1b\\)"),
     lambda m: b"\x1b]4;" + m.group(1) + b";rgb:0000/0000/0000\x07"),
    (re.compile(rb"\x1b\[>c|\x1b\[=c"), lambda m: b"\x1b[>1;4000;0c"),  # DA2
    (re.compile(rb"\x1b\[c|\x1b\[0c"), lambda m: b"\x1b[?62;22c"),      # DA1 (sentinel, last)
]

_qbuf = bytearray()


def respond(data):
    """Answer capability queries aerc just asked. Bounded, no blocking."""
    global kitty_query_answered
    _qbuf.extend(data)
    while True:
        best = None
        for pat, build in _QUERIES:
            m = pat.search(_qbuf)
            if m and (best is None or m.start() < best[0].start()):
                best = (m, build)
        if best is None:
            break
        m, build = best
        try:
            os.write(fd, build(m))
        except OSError:
            pass
        answered.append(m.group(0))
        if m.group(0).startswith(b"\x1b_G"):
            kitty_query_answered = True
        del _qbuf[: m.end()]
    # keep only a query's worth of tail, so a long session cannot grow this
    if len(_qbuf) > 256:
        del _qbuf[: len(_qbuf) - 256]


def pump(timeout):
    """Move pending bytes fifo->pty and pty->capture. False on pty EOF."""
    global last_output
    r, _, _ = select.select([fd, keys_r], [], [], timeout)
    if keys_r in r:
        try:
            k = os.read(keys_r, 4096)
            if k:
                os.write(fd, k)
        except OSError as e:
            if e.errno not in (errno.EAGAIN, errno.EIO):
                raise
    if fd in r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            return False
        if not data:
            return False
        out.write(data)
        seen.extend(data)
        last_output = time.monotonic()
        respond(data)
    return True


def wait_until(pred, limit, until_exit=False):
    """Pump until pred() or `limit` seconds pass. Bounded; never a bare sleep."""
    mark = time.monotonic()
    while time.monotonic() - mark < limit and elapsed() < DEADLINE:
        if pred():
            return True
        if not pump(0.1):
            return pred()
        if until_exit and not alive():
            return pred()
    return pred()


def send(data):
    os.write(keys_w, data)


try:
    # 1. aerc is up and has drawn the message list (the subject is on screen)
    booted = wait_until(lambda: b"PROBEMSG" in seen, BOOT_WAIT)

    if booted and alive():
        # 2. open the message -> aerc runs the text/html filter
        send(b"\r")
        wait_until(lambda: os.path.exists(filter_marker), FILTER_WAIT)
        # 3. let aerc finish its redraw: wait for the pty to go quiet
        wait_until(lambda: time.monotonic() - last_output >= QUIET_FOR, SETTLE_WAIT)
        # 4. close the viewer, then quit
        send(b"q")
        wait_until(lambda: time.monotonic() - last_output >= 0.4, 3.0)
        send(b":quit\r")

    wait_until(lambda: not alive(), EXIT_WAIT, until_exit=True)
    wait_until(lambda: False, 1.0)   # drain whatever is still buffered
finally:
    with open(os.environ["AERC_GFX_PROBE_ROOT"] + "/caps.txt", "w") as cf:
        cf.write("kitty_query_answered=%d\n" % (1 if kitty_query_answered else 0))
        cf.write("queries_answered=%d\n" % len(answered))
    out.close()
    for f in (keys_w, keys_r, fd):
        try:
            os.close(f)
        except OSError:
            pass
    if not reaped:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                break
            for _ in range(30):
                try:
                    if os.waitpid(pid, os.WNOHANG)[0] == pid:
                        reaped = True
                        break
                except ChildProcessError:
                    reaped = True
                    break
                time.sleep(0.1)
            if reaped:
                break
PY

# --- the run has to have been real before the count means anything -----------

[ -s "$capture" ] || { echo "pty capture is empty: aerc emitted nothing" >&2; exit 2; }

if [ -f "$root/aerc.log" ] &&
   grep -qiE 'fatal|panic|permissions too lax|no such file' "$root/aerc.log"; then
  echo "aerc reported a startup failure:" >&2
  cat "$root/aerc.log" >&2
  exit 2
fi

grep -qa 'PROBEMSG' "$capture" || {
  echo "aerc never drew the message list; nothing was opened" >&2
  [ -f "$root/aerc.log" ] && cat "$root/aerc.log" >&2
  exit 3
}

[ -f "$marker" ] || {
  echo "the text/html filter never executed: aerc did not render the HTML part" >&2
  [ -f "$root/aerc.log" ] && cat "$root/aerc.log" >&2
  exit 3
}

# The filter's plain-text marks must reach the wire too. Without this a terminal
# that never displayed the part at all would be scored as "relays nothing".
grep -qa 'PROBE-FILTER-RAN' "$capture" || {
  echo "the filter ran but aerc never put its output on the wire; the viewer" >&2
  echo "was not measured" >&2
  exit 3
}

# The measurement is only about aerc if the harness convinced aerc it was on a
# graphics-capable terminal. An unanswered kitty query would make a zero mean
# "Vaxis saw no host support", which is a fact about this pty, not about aerc.
if ! grep -q '^kitty_query_answered=1$' "$root/caps.txt" 2>/dev/null; then
  echo "aerc never asked the kitty graphics capability question, or the harness" >&2
  echo "failed to answer it; a count would not be attributable to aerc" >&2
  [ -f "$root/caps.txt" ] && cat "$root/caps.txt" >&2
  exit 3
fi

# --- count -------------------------------------------------------------------
n=$(count_apc "$capture") || { echo "counting failed" >&2; exit 2; }

# Evidence for an outside observer. The suite cannot take the probe's word that
# a real aerc ran; with this set it inspects the raw pty capture itself.
if [ -n "${AERC_GFX_PROBE_EVIDENCE:-}" ]; then
  mkdir -p "$AERC_GFX_PROBE_EVIDENCE" &&
  cp -f "$capture" "$AERC_GFX_PROBE_EVIDENCE/capture.bin" &&
  cp -f "$root/caps.txt" "$AERC_GFX_PROBE_EVIDENCE/caps.txt" || {
    echo "could not write evidence to $AERC_GFX_PROBE_EVIDENCE" >&2; exit 2; }
  [ -f "$root/aerc.log" ] && cp -f "$root/aerc.log" "$AERC_GFX_PROBE_EVIDENCE/aerc.log"
  printf 'control_apc_chunks=%s\napc_chunks=%s\n' "$control_n" "$n" \
    > "$AERC_GFX_PROBE_EVIDENCE/counts.txt"
fi

echo "control_apc_chunks=$control_n (plain pty; harness sanity)" >&2
echo "apc_chunks=$n"
