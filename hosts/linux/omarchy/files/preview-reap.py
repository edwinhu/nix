"""Reap abandoned preview servers: tinymist previews, static preview servers
and tailscale origin proxies.

Nothing else sweeps them. typst-preview.nvim cleans up on VimLeavePre and the
nvim config's reap_orphans runs only when a NEW nvim opens a Typst file, so a
closed browser tab with nvim still running leaves a tinymist server on ~5.5 GiB
until the editor exits. The `preview` skill is worse: it spawns its static
server and origin proxy with `setsid nohup` and only ever cleans up on an
explicit `preview --stop` that nothing calls, so every invocation leaks a
listener. This is the sweep, on a clock, for all three.

Each process class is a rule in RULES: a `name`, a `match(proc)` that selects
it, and an `idle(proc, ctx)` that says whether it looked unused on this run.
A rule may also carry `orphan(proc)` for a signal strong enough to kill on
sight. Every rule shares one strike file, one kill loop and SIGTERM, and needs
STRIKES_TO_KILL consecutive idle observations before it kills.

  tinymist        comm is `tinymist` with `preview` among its argv.
                  ORPHAN: parent is readable and is not nvim -> the editor is
                  gone, kill immediately.
                  IDLE: no ESTABLISHED client AND no CPU burned since the last
                  run. Both are needed: closing a tab does NOT promptly drop
                  the socket (chromium holds it for hours) so "no client" alone
                  fires late, and a watched-but-still preview burns no CPU
                  either.

  preview-static  a python running `http.server` with `--directory`.

                  Parent-gone does NOT transfer to this one, nor to the proxy
                  below. They are launched through `setsid`, which exits the
                  instant it forks, so they are reparented to `systemd --user`
                  AT BIRTH -- a server spawned two seconds ago is
                  indistinguishable from a three-day orphan by ppid alone, and
                  the tinymist rule would reap live previews instantly. What
                  does work HERE is the request log: the http.server module
                  appends a line on EVERY request, so
                  <LOG_DIR>/preview-static-<port>.log has a true "last used"
                  mtime. IDLE is that mtime older than IDLE_LOG_SECONDS AND no
                  CPU burned since the last run.

                  Which log is a process's own is decided by /proc/<pid>/fd/1
                  (then fd/2), NOT by a port number read out of argv. Nothing
                  deletes these logs -- `preview --stop` pkills the server and
                  leaves the file -- so a log outlives its server by days, and
                  a hand-run `python3 -m http.server <port> --directory .` on a
                  recycled port would adopt it, never refresh it, and be killed
                  while in use. A server preview.sh spawned holds its log open
                  as stdout; one whose stdout is a tty, a pipe or /dev/null owns
                  no log. No log means "cannot tell", which is never idle.

  origin-proxy    a python running `origin-proxy.py` that ALSO holds
                  <LOG_DIR>/preview-origin-proxy-<port>.log open as its own
                  output. Both halves are the match. Argv alone is not
                  provenance: a copy run by hand, one from a second checkout,
                  or a proxy stopped at a pdb breakpoint carries the same
                  filename and belongs to nobody here. Only preview.sh
                  redirects a proxy's stdout into that log, so holding it is
                  the evidence that this process is one of ours; owning no log
                  means "not ours", which is never selected.

                  The log is proof of ORIGIN only, never a last-used stamp.
                  The proxy is a bare asyncio socket splice with no print, no
                  stderr write and no logger: preview.sh creates the file
                  purely as a shell redirection target, so it stays empty and
                  its mtime is frozen at spawn for the life of the process.
                  Keyed on that mtime every proxy is permanently "idle" half an
                  hour after it starts, however heavily used, and a tailnet
                  preview held open on a phone is SIGTERMed in use.
                  IDLE is therefore the tinymist signal: no ESTABLISHED client
                  AND no CPU burned since the last run. An abandoned proxy
                  holds only its LISTENING socket, so it still reaps; one a
                  client is attached to does not.

PID reuse is guarded by pinning each entry to the process start time, so a
recycled pid cannot inherit another process's strike count.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time

STRIKES_TO_KILL = 2
IDLE_LOG_SECONDS = 30 * 60
LOG_DIR = "/tmp"
STATE = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "preview-reap.json")


def procs():
    """Every live process, as {pid, ppid, start, cpu, comm, args, cmd}."""
    out = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/comm") as fh:
                comm = fh.read().strip()
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                raw = fh.read().split(b"\0")
            args = [a.decode(errors="replace") for a in raw if a]
            if not args:
                continue  # kernel thread
            with open(f"/proc/{pid}/stat") as fh:
                # comm can contain spaces; everything after the final ')'
                fields = fh.read().rsplit(")", 1)[1].split()
            # stat fields after comm are offset by 2 from the man page numbering
            cpu = int(fields[11]) + int(fields[12])   # utime + stime
            start = fields[19]                        # starttime
            ppid = fields[1]
            out.append({"pid": int(pid), "ppid": int(ppid), "start": start,
                        "cpu": cpu, "comm": comm, "args": args,
                        "cmd": " ".join(args)})
        except (OSError, ValueError, IndexError):
            continue  # died mid-scan, or unreadable
    return out


def comm_of(pid):
    try:
        with open(f"/proc/{pid}/comm") as fh:
            return fh.read().strip()
    except OSError:
        return None


def established_inodes():
    """Socket inodes currently in TCP state ESTABLISHED (01)."""
    inodes = set()
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(path) as fh:
                next(fh, None)
                for line in fh:
                    f = line.split()
                    if len(f) > 9 and f[3] == "01":
                        inodes.add(f[9])
        except OSError:
            pass
    return inodes


def has_client(pid, estab):
    """True if this process owns a socket that is ESTABLISHED."""
    try:
        fds = os.listdir(f"/proc/{pid}/fd")
    except OSError:
        return True  # unreadable: assume in use rather than kill blind
    for fd in fds:
        try:
            target = os.readlink(f"/proc/{pid}/fd/{fd}")
        except OSError:
            continue
        if target.startswith("socket:[") and target[8:-1] in estab:
            return True
    return False


def owned_log(pid, prefix):
    """The request log this pid itself holds open as its output, or None.

    Ownership has to come from the process. A port number out of argv only
    says which log some server once used, and those files are never deleted,
    so an unrelated server on a recycled port would inherit a log it never
    writes to and read as idle forever. preview.sh redirects its server's
    stdout (and stderr onto it) into the log, so /proc/<pid>/fd/1 names it;
    a tty, a pipe, a socket or /dev/null names no log at all.
    """
    log_dir = os.path.realpath(LOG_DIR)
    for fd in ("1", "2"):
        try:
            target = os.readlink(f"/proc/{pid}/fd/{fd}")
        except OSError:
            continue
        # A deleted file readlinks as "<path> (deleted)", which fails the
        # basename match below and is rejected along with everything else.
        if os.path.realpath(os.path.dirname(target)) != log_dir:
            continue
        got = re.fullmatch(re.escape(prefix) + r"-(\d+)\.log",
                           os.path.basename(target))
        if not got or not 0 < int(got.group(1)) < 65536:
            continue
        if os.path.isfile(target):
            return target
    return None


def request_log_mtime(prefix, proc):
    """mtime of the request log this process owns; None means "no idea"."""
    path = owned_log(proc["pid"], prefix)
    if path is None:
        return None
    try:
        return os.stat(path).st_mtime
    except OSError:
        return None


def cpu_unchanged(proc, ctx):
    """True only on a SECOND sighting whose CPU counter has not moved."""
    prev = ctx["prev"]
    return prev is not None and prev["cpu"] == proc["cpu"]


def log_idle(prefix):
    def idle(proc, ctx):
        mtime = request_log_mtime(prefix, proc)
        if mtime is None:
            return False
        return (ctx["now"] - mtime) > IDLE_LOG_SECONDS and cpu_unchanged(proc, ctx)
    return idle


class Rule:
    def __init__(self, name, match, idle, orphan=None):
        self.name = name
        self.match = match
        self.idle = idle
        self.orphan = orphan


def _tinymist_orphan(proc):
    # Only ever on a POSITIVE read. An unreadable parent tells us nothing, and
    # "not nvim" on a failed read would kill a live preview.
    parent = comm_of(proc["ppid"])
    if parent is not None and parent != "nvim":
        return "orphan (editor gone)"
    return None


# Shared by tinymist and origin-proxy: both are judged by a live client plus a
# CPU delta, because neither has a log whose mtime moves when it is used.
def _tinymist_idle(proc, ctx):
    return not has_client(proc["pid"], ctx["estab"]) and cpu_unchanged(proc, ctx)


def _origin_proxy_match(proc):
    """argv shape AND provenance: it must hold preview.sh's log as its output.

    The log is the ownership gate here, not a last-used stamp -- its mtime is
    frozen at spawn (see the module docstring). No such log means "not one of
    preview.sh's", which is never selected, let alone killed.
    """
    return (proc["comm"].startswith("python")
            and any(a.endswith("origin-proxy.py") for a in proc["args"])
            and owned_log(proc["pid"], "preview-origin-proxy") is not None)


RULES = [
    Rule(
        name="tinymist",
        # the plain LSP is not a preview server
        match=lambda p: p["comm"] == "tinymist" and "preview" in p["args"],
        idle=_tinymist_idle,
        orphan=_tinymist_orphan,
    ),
    Rule(
        name="preview-static",
        match=lambda p: (p["comm"].startswith("python")
                         and "http.server" in p["args"]
                         and "--directory" in p["args"]),
        idle=log_idle("preview-static"),
    ),
    Rule(
        name="origin-proxy",
        match=_origin_proxy_match,
        # NOT log_idle: the proxy never writes to its log (see the docstring).
        idle=_tinymist_idle,
    ),
]


def rule_for(proc):
    for rule in RULES:
        try:
            if rule.match(proc):
                return rule
        except (KeyError, ValueError):
            continue
    return None


def notify(msg):
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-a", "preview-reap",
                        "Reaped an abandoned preview server", msg], check=False)


def main():
    try:
        with open(STATE) as fh:
            state = json.load(fh)
    except (OSError, ValueError):
        state = {}

    ctx = {"estab": established_inodes(), "now": time.time(), "prev": None}
    fresh, killed = {}, []

    for p in procs():
        rule = rule_for(p)
        if rule is None:
            continue
        pid, key = p["pid"], f"{p['pid']}:{p['start']}"

        reason = rule.orphan(p) if rule.orphan else None
        if reason is None:
            prev = state.get(key)
            ctx["prev"] = prev
            idle = rule.idle(p, ctx)
            strikes = (prev["strikes"] + 1) if (idle and prev) else 0
            if strikes < STRIKES_TO_KILL:
                fresh[key] = {"cpu": p["cpu"], "strikes": strikes}
                continue
            reason = f"idle, {strikes} checks"

        try:
            os.kill(pid, 15)
            killed.append((pid, rule.name, reason, p["cmd"]))
        except OSError:
            pass

    try:
        with open(STATE, "w") as fh:
            json.dump(fresh, fh)
    except OSError:
        pass

    for pid, name, reason, cmd in killed:
        target = cmd.split()[-1] if cmd else "?"
        line = f"pid {pid} — {name} — {reason} — {os.path.basename(target)}"
        print(line, flush=True)
        notify(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
