#!/usr/bin/env python3
"""Run mbsync for a channel or group, then index, refusing a suspicious push.

Usage: mbsync-guarded.py <mbsync> <mbsyncrc> <notmuch> <channel|group>

The channels push flags (`Sync Pull PushFlags`). A message whose Seen flag was
lost LOCALLY -- a tag write racing an unindexed rename strips it -- looks to
mbsync exactly like the user marking it unread, and would be pushed upstream as
unread. So count the pending unread pushes first; past the limit, pull only and
say so, rather than mark a batch of read mail unread in Outlook or Gmail.

`notmuch new` runs here, inside the caller's lock, so no tag write can see a
rename mbsync made before notmuch has indexed it.
"""
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.expanduser("~/areas/mail")
CHANNELS = {"work": ["work"], "personal": ["personal"], "mail": ["work", "personal"]}
UNREAD_PUSH_LIMIT = 25
NAME = re.compile(r",U=(\d+):2,([A-Z]*)$")


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


def main(argv):
    mbsync, rc, notmuch, target = argv[1:5]
    accounts = CHANNELS.get(target, [target])
    pending = {a: pending_unread_pushes(os.path.join(ROOT, a)) for a in accounts}
    cmd = [mbsync, "--config", rc]
    if any(n > UNREAD_PUSH_LIMIT for n in pending.values()):
        print(f"mbsync-guarded: HOLDING flag push, pending unread pushes {pending} "
              f"exceed {UNREAD_PUSH_LIMIT}; pulling only", file=sys.stderr)
        cmd.append("--pull")
    status = subprocess.run(cmd + [target], check=False).returncode
    subprocess.run([notmuch, "new", "--quiet"], check=False)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
