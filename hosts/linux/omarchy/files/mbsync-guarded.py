#!/usr/bin/env python3
"""Run mbsync per account, then index, refusing a suspicious push.

Usage: mbsync-guarded.py <mbsync> <mbsyncrc> <notmuch> <channel|group> [--wait SECONDS]

The channels push flags (`Sync Pull PushFlags`). A message whose Seen flag was
lost LOCALLY -- a tag write racing an unindexed rename strips it -- looks to
mbsync exactly like the user marking it unread, and would be pushed upstream as
unread. So count the pending unread pushes first; past the limit, pull only and
say so, rather than mark a batch of read mail unread in Outlook or Gmail.

Locks, all under ROOT. Each account syncs under its OWN exclusive lock, so a slow
Gmail pull never holds up Work. Every sync also holds the shared `.mbsync.lock`
in SHARED mode until its `notmuch new` is done: the taggers take that lock
exclusively, so no tag write lands between a rename and its indexing, while the
two accounts still sync side by side. `notmuch new` itself is serialized on
`.notmuch.lock`. A busy account is skipped, or with `--wait` waited for -- a
notification must queue behind an in-flight pull, not vanish.
"""
import fcntl
import glob
import os
import re
import subprocess
import sys
import time

ROOT = os.path.expanduser("~/areas/mail")
CHANNELS = {"work": ["work"], "personal": ["personal"], "mail": ["work", "personal"]}
UNREAD_PUSH_LIMIT = 25
NAME = re.compile(r",U=(\d+):2,([A-Z]*)$")
# How long a sync waits for the taggers to release the shared lock; they run
# under `flock -w 120` and finish in seconds.
SHARED_WAIT_S = 120


def pending_unread_pushes(account_dir):
    """Messages mbsync last recorded as Seen whose local file has lost Seen."""
    count = 0
    for state in glob.glob(os.path.join(account_dir, "**", ".mbsyncstate"), recursive=True):
        box = os.path.dirname(state)
        local = {}
        for sub in ("cur", "new"):
            try:
                names = os.listdir(os.path.join(box, sub))
            except OSError:
                continue
            for name in names:
                m = NAME.search(name)
                if m:
                    local[m.group(1)] = m.group(2)
        with open(state) as f:
            for line in f:
                parts = line.split()
                # Far UID 0 means the message is gone upstream: nothing to push to.
                if (len(parts) < 2 or not parts[0].isdigit() or parts[0] == "0"
                        or parts[1] not in local):
                    continue
                recorded = parts[2] if len(parts) > 2 else ""
                if "S" in recorded and "S" not in local[parts[1]]:
                    count += 1
    return count


def lock(name, mode, wait_s):
    """An fd holding `mode` on ROOT/name, or None if not had within wait_s."""
    fd = os.open(os.path.join(ROOT, name), os.O_RDWR | os.O_CREAT, 0o600)
    deadline = time.monotonic() + wait_s
    while True:
        try:
            fcntl.flock(fd, mode | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(fd)
                return None
            time.sleep(0.2)


def sync(mbsync, rc, notmuch, account, wait_s):
    own = lock(f".mbsync-{account}.lock", fcntl.LOCK_EX, wait_s)
    if own is None:
        print(f"mbsync-guarded: {account} sync already running; skipped", file=sys.stderr)
        return 0
    try:
        shared = lock(".mbsync.lock", fcntl.LOCK_SH, SHARED_WAIT_S)
        if shared is None:
            print(f"mbsync-guarded: {account}: taggers held the lock {SHARED_WAIT_S}s; skipped",
                  file=sys.stderr)
            return 0
        try:
            cmd = [mbsync, "--config", rc]
            pending = pending_unread_pushes(os.path.join(ROOT, account))
            if pending > UNREAD_PUSH_LIMIT:
                print(f"mbsync-guarded: HOLDING flag push, {pending} pending unread pushes "
                      f"in {account} exceed {UNREAD_PUSH_LIMIT}; pulling only", file=sys.stderr)
                cmd.append("--pull")
            status = subprocess.run(cmd + [account], check=False).returncode
            indexer = lock(".notmuch.lock", fcntl.LOCK_EX, SHARED_WAIT_S)
            try:
                subprocess.run([notmuch, "new", "--quiet"], check=False)
            finally:
                if indexer is not None:
                    os.close(indexer)
            return status
        finally:
            os.close(shared)
    finally:
        os.close(own)


def main(argv):
    mbsync, rc, notmuch, target = argv[1:5]
    rest = argv[5:]
    wait_s = float(rest[rest.index("--wait") + 1]) if "--wait" in rest else 0.0
    status = 0
    for account in CHANNELS.get(target, [target]):
        status = sync(mbsync, rc, notmuch, account, wait_s) or status
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
