"""Reap abandoned `tinymist preview` servers.

typst-preview.nvim cleans up on VimLeavePre, and the nvim config's own
reap_orphans sweeps parent-gone servers -- but only when a NEW nvim opens a
Typst file. Close the browser tab and leave nvim running and nothing ever
sweeps: the server sits on ~5.5 GiB until the editor exits. This is that
sweep on a clock.

Two rules, because the obvious signal does not work on its own:

  ORPHAN   parent is not nvim -> the editor is gone. Kill immediately.
           (Same rule as reap_orphans; this just runs without an nvim.)

  IDLE     no ESTABLISHED client AND no CPU consumed, on two consecutive
           runs. Both are needed. Closing a tab does NOT promptly drop the
           socket -- chromium holds it open for hours -- so "no client" alone
           fires late and says little; and an idle-but-watched preview burns
           no CPU either. Requiring both, twice, is what makes it safe.

PID reuse is guarded by pinning each entry to the process start time, so a
recycled pid cannot inherit another process's strike count.
"""

import json
import os
import shutil
import subprocess
import sys

STRIKES_TO_KILL = 2
STATE = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "tinymist-reap.json")


def procs():
    """Every live `tinymist preview`, as (pid, starttime, cputicks, cmdline)."""
    out = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/comm") as fh:
                if fh.read().strip() != "tinymist":
                    continue
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                args = fh.read().split(b"\0")
            if b"preview" not in args:
                continue  # the plain LSP is not a preview server
            with open(f"/proc/{pid}/stat") as fh:
                # comm can contain spaces; everything after the final ')'
                fields = fh.read().rsplit(")", 1)[1].split()
            # stat fields after comm are offset by 2 from the man page numbering
            cpu = int(fields[11]) + int(fields[12])   # utime + stime
            start = fields[19]                        # starttime
            ppid = fields[1]
            out.append({"pid": int(pid), "ppid": int(ppid), "start": start,
                        "cpu": cpu,
                        "cmd": b" ".join(a for a in args if a).decode(errors="replace")})
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


def notify(msg):
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-a", "tinymist-reap",
                        "Reaped a Typst preview", msg], check=False)


def main():
    try:
        with open(STATE) as fh:
            state = json.load(fh)
    except (OSError, ValueError):
        state = {}

    estab = established_inodes()
    fresh, killed = {}, []

    for p in procs():
        pid, key = p["pid"], f"{p['pid']}:{p['start']}"
        parent = comm_of(p["ppid"])

        # ORPHAN: only ever on a POSITIVE read. An unreadable parent tells us
        # nothing, and "not nvim" on a failed read would kill a live preview.
        if parent is not None and parent != "nvim":
            reason = "orphan (editor gone)"
        else:
            prev = state.get(key)
            idle = not has_client(pid, estab) and prev is not None and prev["cpu"] == p["cpu"]
            strikes = (prev["strikes"] + 1) if (idle and prev) else 0
            if strikes < STRIKES_TO_KILL:
                fresh[key] = {"cpu": p["cpu"], "strikes": strikes}
                continue
            reason = f"idle, no client, {strikes} checks"

        try:
            os.kill(pid, 15)
            killed.append((pid, reason, p["cmd"]))
        except OSError:
            pass

    try:
        with open(STATE, "w") as fh:
            json.dump(fresh, fh)
    except OSError:
        pass

    for pid, reason, cmd in killed:
        doc = cmd.split()[-1] if cmd else "?"
        line = f"pid {pid} — {reason} — {os.path.basename(doc)}"
        print(line, flush=True)
        notify(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
