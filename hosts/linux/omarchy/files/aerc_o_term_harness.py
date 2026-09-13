"""Drive a fixture aerc on a pty and watch what pressing `o` actually spawns.

Two ways in:

  * as a library -- build_fixture() writes a one-message maildir and accounts
    file, Session() runs aerc on a pty this process answers queries for, and
    descendants()/kitty_commands() report what the keypress produced;
  * as a CLI -- `fixture` writes that maildir, `proxy` runs the same aerc on a
    pty nested inside a REAL terminal, relaying bytes untouched so the terminal
    itself answers vaxis's probes. The proxy is what a screenshot run drives.

Fixture aerc always runs with -I (no IPC) and its own accounts file, so it can
never reach the user's live session.
"""

import argparse
import base64
import email.utils
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import threading
import time
import tty
import zlib
from pathlib import Path

AERC_CONF = Path.home() / ".config/aerc/aerc.conf"
BINDS_CONF = Path.home() / ".config/aerc/binds.conf"

# Everything a multiplexer uses to advertise a pane. A fixture aerc must not see
# any of it, or a browser launched from it hunts for a pane to split instead of
# taking the terminal it was handed.
MUX_VARS = (
    "HERDR_PANE_ID", "HERDR_SOCKET_PATH", "HERDR_SESSION", "HERDR_TAB_ID",
    "HERDR_CONFIG_PATH", "HERDR_BIN_PATH", "HERDR_ENV",
    "TMUX", "TMUX_PANE", "ZELLIJ", "WEZTERM_PANE", "KITTY_WINDOW_ID",
    "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID",
)

CSI_RE = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[P_^][^\x1b]*\x1b\\"
                    rb"|\x1b\[[0-9;?<>!$\" ]*[A-Za-z@`{|}~]"
                    rb"|\x1b[()][A-Za-z0-9]|\x1b[=><A-Za-z0-9]")
KITTY_RE = re.compile(rb"\x1b_G.*?\x1b\\", re.DOTALL)


# --------------------------------------------------------------------------
# fixture


def _red_png():
    """A 64x64 solid red PNG, written by hand so no image library is needed."""
    def chunk(kind, payload):
        body = kind + payload
        return (struct.pack(">I", len(payload)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    side = 64
    raw = b"".join(b"\x00" + b"\xff\x00\x00" * side for _ in range(side))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


MESSAGE_TEMPLATE = """MIME-Version: 1.0
Date: {date}
Message-ID: <o-term-fixture@example.invalid>
Subject: O-TERM FIXTURE subject
From: Fixture <fixture@example.invalid>
To: Fixture <fixture@example.invalid>
Content-Type: multipart/alternative; boundary="oterm"

--oterm
Content-Type: text/plain; charset=utf-8

O-TERM FIXTURE
--oterm
Content-Type: text/html; charset=utf-8

<html><body><h1>O-TERM FIXTURE</h1><p>fixture body text</p>\
<img src="data:image/png;base64,{png}" width=200 height=200></body></html>
--oterm--
"""


def build_fixture(root):
    """Write a one-message maildir plus the accounts file that points at it.

    `maildir://` wants the directory CONTAINING the maildirs, so the message
    lands in <root>/mail/INBOX and the account defaults to INBOX.
    """
    root = Path(root)
    inbox = root / "mail/INBOX"
    for sub in ("cur", "new", "tmp"):
        (inbox / sub).mkdir(parents=True, exist_ok=True)
    message = MESSAGE_TEMPLATE.format(
        date=email.utils.formatdate(localtime=True),
        png=base64.b64encode(_red_png()).decode("ascii"),
    )
    name = f"{int(time.time())}.oterm{os.getpid()}.fixture:2,S"
    (inbox / "cur" / name).write_text(message)

    accounts = root / "accounts.conf"
    accounts.write_text(
        "[fixture]\n"
        "source   = maildir://" + str(root / "mail") + "\n"
        "default  = INBOX\n"
        "from     = Fixture <fixture@example.invalid>\n"
        "outgoing = /usr/bin/true\n"
    )
    accounts.chmod(0o600)
    return accounts


# --------------------------------------------------------------------------
# session


def strip_escapes(data):
    return CSI_RE.sub(b"", data).replace(b"\r", b"\n")


def _set_winsize(fd, cols, rows, xpx, ypx):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, xpx, ypx))


class Session:
    """A fixture aerc on a pty this process owns both ends of."""

    def __init__(self):
        self.pid = None
        self.fd = None
        self.buffer = bytearray()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._reader = None
        self._answered = set()
        self._geometry = (120, 40, 1920, 1280)
        self.exit_code = None

    # -- lifecycle

    def start(self, aerc_bin, accounts, cols=120, rows=40, xpx=1920, ypx=1280,
              extra_env=None, responder=True):
        self._geometry = (cols, rows, xpx, ypx)
        self.responder = responder
        env = {k: v for k, v in os.environ.items() if k not in MUX_VARS}
        env.update(
            TERM="xterm-256color",
            COLORTERM="truecolor",
            HOME=os.environ.get("HOME", str(Path.home())),
            PATH=os.environ.get("PATH", "/usr/bin:/bin"),
        )
        if extra_env:
            env.update(extra_env)
        argv = [str(aerc_bin), "-I",
                "-C", str(AERC_CONF), "-B", str(BINDS_CONF),
                "-A", str(accounts)]
        pid, fd = pty.fork()
        if pid == 0:
            try:
                _set_winsize(0, cols, rows, xpx, ypx)
                os.execve(argv[0], argv, env)
            finally:
                os._exit(127)
        self.pid = pid
        self.fd = fd
        _set_winsize(fd, cols, rows, xpx, ypx)
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()
        return self

    def _read_loop(self):
        while not self._stop.is_set():
            try:
                ready, _, _ = select.select([self.fd], [], [], 0.2)
            except (OSError, ValueError):
                return
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            with self._lock:
                self.buffer += chunk
            if self.responder:
                self._answer(chunk)

    def _answer(self, chunk):
        """Reply to vaxis's startup probes. DA1 goes LAST, as a real terminal's
        answers arrive in the order the queries were issued and aerc waits on
        DA1 to conclude the negotiation."""
        cols, rows, xpx, ypx = self._geometry
        replies = []
        if b"\x1b_Gi=1,a=q\x1b\\" in chunk and "kitty" not in self._answered:
            self._answered.add("kitty")
            replies.append(b"\x1b_Gi=1;OK\x1b\\")
        if b"\x1b[14t" in chunk and "px" not in self._answered:
            self._answered.add("px")
            replies.append(b"\x1b[4;%d;%dt" % (ypx, xpx))
        if b"\x1b[16t" in chunk and "cell" not in self._answered:
            self._answered.add("cell")
            replies.append(b"\x1b[6;%d;%dt" % (ypx // rows, xpx // cols))
        if b"\x1b[18t" in chunk and "grid" not in self._answered:
            self._answered.add("grid")
            replies.append(b"\x1b[8;%d;%dt" % (rows, cols))
        if re.search(rb"\x1b\[c", chunk) and "da1" not in self._answered:
            self._answered.add("da1")
            replies.append(b"\x1b[?62;4;22c")
        for reply in replies:
            try:
                os.write(self.fd, reply)
            except OSError:
                return
            time.sleep(0.01)

    # -- inspection

    def raw(self):
        with self._lock:
            return bytes(self.buffer)

    def offset(self):
        with self._lock:
            return len(self.buffer)

    def text(self, since=0):
        return strip_escapes(self.raw()[since:]).decode("utf-8", "replace")

    def wait_for_text(self, substr, timeout=30.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if substr in self.text():
                return True
            time.sleep(0.1)
        return False

    def send(self, text):
        os.write(self.fd, text.encode() if isinstance(text, str) else text)

    def kitty_commands(self, since=0):
        return [m.group(0) for m in KITTY_RE.finditer(self.raw()[since:])]

    def descendants(self):
        """Every process whose parent chain reaches the aerc pid."""
        parents = {}
        commands = {}
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                stat = (entry / "stat").read_text()
                parents[int(entry.name)] = int(stat.rsplit(")", 1)[1].split()[1])
                commands[int(entry.name)] = (
                    (entry / "cmdline").read_bytes().replace(b"\0", b" ")
                    .decode("utf-8", "replace").strip())
            except (OSError, ValueError, IndexError):
                continue
        out = []
        for pid in parents:
            seen = set()
            walk = pid
            while walk > 1 and walk not in seen:
                seen.add(walk)
                walk = parents.get(walk, 0)
                if walk == self.pid:
                    out.append((pid, commands.get(pid, "")))
                    break
        return out

    def close(self):
        try:
            self.send(":quit\r")
        except OSError:
            pass
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if self._collect() is not None:
                break
            time.sleep(0.1)
        if self.exit_code is None:
            try:
                os.killpg(os.getpgid(self.pid), signal.SIGTERM)
            except (OSError, ProcessLookupError):
                pass
            for _ in range(50):
                if self._collect() is not None:
                    break
                time.sleep(0.1)
        self._stop.set()
        if self._reader:
            self._reader.join(timeout=2)
        try:
            os.close(self.fd)
        except OSError:
            pass
        return self.exit_code

    def _collect(self):
        if self.exit_code is not None:
            return self.exit_code
        try:
            waited, status = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            self.exit_code = -1
            return self.exit_code
        if waited == self.pid:
            self.exit_code = (os.waitstatus_to_exitcode(status)
                              if hasattr(os, "waitstatus_to_exitcode")
                              else status)
        return self.exit_code


# --------------------------------------------------------------------------
# proxy CLI


def _outer_winsize(fd):
    """Cols, rows and PIXELS of the real terminal we are running inside."""
    try:
        rows, cols, xpx, ypx = struct.unpack(
            "HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8))
    except OSError:
        rows, cols, xpx, ypx = 40, 120, 0, 0
    rows = rows or 40
    cols = cols or 120
    if not xpx or not ypx:
        xpx, ypx = _query_pixels(fd, cols, rows)
    return cols, rows, xpx, ypx


def _query_pixels(fd, cols, rows):
    """Ask the outer terminal for its pixel size; fall back to a 16x32 cell."""
    try:
        saved = termios.tcgetattr(fd)
    except termios.error:
        return cols * 16, rows * 32
    try:
        tty.setraw(fd)
        os.write(fd, b"\x1b[14t")
        deadline = time.monotonic() + 1.0
        data = b""
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if not ready:
                continue
            data += os.read(fd, 64)
            match = re.search(rb"\x1b\[4;(\d+);(\d+)t", data)
            if match:
                return int(match.group(2)), int(match.group(1))
    except OSError:
        pass
    finally:
        try:
            termios.tcsetattr(fd, termios.TCSANOW, saved)
        except termios.error:
            pass
    return cols * 16, rows * 32


def parse_keys(spec):
    """`6:\\r,12:o` -> [(6.0, '\\r'), (12.0, 'o')], seconds from start."""
    out = []
    for item in spec.split(","):
        if not item.strip():
            continue
        when, _, keys = item.partition(":")
        out.append((float(when), keys.encode().decode("unicode_escape")))
    return sorted(out)


def run_proxy(args):
    keys = parse_keys(args.keys)
    outer = sys.stdin.fileno()
    cols, rows, xpx, ypx = _outer_winsize(outer)
    if args.cols:
        cols = args.cols
    if args.rows:
        rows = args.rows

    env = {k: v for k, v in os.environ.items() if k not in MUX_VARS}
    env.update(TERM=os.environ.get("TERM", "xterm-256color"),
               COLORTERM="truecolor")
    argv = [str(args.aerc), "-I", "-C", str(AERC_CONF), "-B", str(BINDS_CONF),
            "-A", str(args.accounts)]

    pid, fd = pty.fork()
    if pid == 0:
        try:
            _set_winsize(0, cols, rows, xpx, ypx)
            os.execve(argv[0], argv, env)
        finally:
            os._exit(127)
    _set_winsize(fd, cols, rows, xpx, ypx)

    report = {
        "schedule": [{"at": at, "keys": repr(k)} for at, k in keys],
        "geometry": {"cols": cols, "rows": rows, "xpx": xpx, "ypx": ypx},
        "watch": args.watch,
        "ticks": [],
        "first_seen_at": None,
        "last_seen_at": None,
        "sample": None,
        "seen": False,
        "aerc_exit": None,
        # What the OUTER terminal sent inward, bounded. A stray keystroke in
        # here is the difference between "aerc did that" and "the terminal did".
        "relayed": [],
    }

    saved = None
    try:
        saved = termios.tcgetattr(outer)
        tty.setraw(outer)
    except termios.error:
        pass

    start = time.monotonic()
    pending = list(keys)
    watch_from = keys[1][0] if len(keys) > 1 else (keys[0][0] if keys else 0)
    next_tick = watch_from
    last_key = keys[-1][0] if keys else 0
    deadline = last_key + 10
    exited = None
    try:
        while True:
            now = time.monotonic() - start
            if exited is None:
                try:
                    waited, status = os.waitpid(pid, os.WNOHANG)
                    if waited == pid:
                        exited = os.waitstatus_to_exitcode(status)
                        break
                except ChildProcessError:
                    exited = -1
                    break
            if now > deadline:
                break
            while pending and pending[0][0] <= now:
                _, text = pending.pop(0)
                try:
                    os.write(fd, text.encode())
                except OSError:
                    pass
            if now >= next_tick:
                hit = _watch_sample(pid, args.watch)
                report["ticks"].append(
                    {"at": round(now, 2), "seen": bool(hit)})
                if hit:
                    report["seen"] = True
                    report["sample"] = hit
                    if report["first_seen_at"] is None:
                        report["first_seen_at"] = round(now, 2)
                    report["last_seen_at"] = round(now, 2)
                next_tick += 0.5
            ready, _, _ = select.select([outer, fd], [], [], 0.05)
            if fd in ready:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    break
                if not data:
                    break
                os.write(1, data)
            if outer in ready:
                try:
                    data = os.read(outer, 4096)
                except OSError:
                    data = b""
                if data:
                    if len(report["relayed"]) < 60:
                        report["relayed"].append(
                            {"at": round(now, 2), "bytes": repr(data)})
                    try:
                        os.write(fd, data)
                    except OSError:
                        break
    finally:
        if saved is not None:
            try:
                termios.tcsetattr(outer, termios.TCSADRAIN, saved)
            except termios.error:
                pass
        if exited is None:
            try:
                os.killpg(os.getpgid(pid), signal.SIGTERM)
            except (OSError, ProcessLookupError):
                pass
            try:
                waited, status = os.waitpid(pid, 0)
                exited = os.waitstatus_to_exitcode(status)
            except ChildProcessError:
                exited = -1
        report["aerc_exit"] = exited
        report["ended_at"] = round(time.monotonic() - start, 2)
        Path(args.report).write_text(json.dumps(report, indent=2))
    return 0


def _watch_sample(root_pid, needle):
    parents, commands = {}, {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            stat = (entry / "stat").read_text()
            parents[int(entry.name)] = int(stat.rsplit(")", 1)[1].split()[1])
            commands[int(entry.name)] = (
                (entry / "cmdline").read_bytes().replace(b"\0", b" ")
                .decode("utf-8", "replace").strip())
        except (OSError, ValueError, IndexError):
            continue
    for pid, cmd in commands.items():
        if needle not in cmd:
            continue
        walk, seen = pid, set()
        while walk > 1 and walk not in seen:
            seen.add(walk)
            walk = parents.get(walk, 0)
            if walk == root_pid:
                return cmd
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    make = sub.add_parser("fixture")
    make.add_argument("--out", required=True)

    proxy = sub.add_parser("proxy")
    proxy.add_argument("--aerc", required=True)
    proxy.add_argument("--accounts", required=True)
    proxy.add_argument("--keys", required=True)
    proxy.add_argument("--report", required=True)
    proxy.add_argument("--watch", required=True)
    proxy.add_argument("--cols", type=int)
    proxy.add_argument("--rows", type=int)

    args = parser.parse_args(argv)
    if args.command == "fixture":
        out = Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        print(build_fixture(out))
        return 0
    return run_proxy(args)


if __name__ == "__main__":
    raise SystemExit(main())
