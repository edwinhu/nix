#!/usr/bin/env python3
"""Copy mail-bridge's provider metadata onto notmuch tags.

The Focused/Other verdict and the category labels are Graph's, and they never
reach the Maildir: `rawMessage` serves provider bytes verbatim, so nothing in
the file records them. They ARE in the bridge's own UID map, beside the
`InternetMessageId` -- which is exactly notmuch's key. So the two can simply be
joined, and neither the served bytes nor the folder layout has to change.

Idempotent: every message the map knows about is assigned its full tag set on
every run, and stale tags are removed in the same operation, so a reclassified
message converges rather than accumulating.

Only tags messages the map still lists as present. A message the map has
forgotten keeps whatever tags it had -- removing them would need a second
source of truth about what this script wrote, and being slightly stale is
cheaper than being wrong.
"""
import glob, json, os, sqlite3, subprocess, sys

# Category label -> notmuch tag. Anything not listed is ignored rather than
# guessed at: a tag nobody queries is noise in every `notmuch search` output.
CATEGORY_TAGS = {
    "Respond": "respond", "Waiting": "waiting", "Invoice": "invoice",
    "Marketing": "marketing", "Meeting": "meeting", "News": "news",
    "Pitch": "pitch",
}
VIEW_TAGS = {"focused": "focused", "other": "other"}
MANAGED = set(CATEGORY_TAGS.values()) | set(VIEW_TAGS.values())


def maps():
    """Every UID map on this host, newest first."""
    found = glob.glob(os.path.expanduser("~/.config/owa-bridge/imap-uidmap-*.db"))
    return sorted(found, key=os.path.getmtime, reverse=True)


def rows(db):
    # read-only, and NOT immutable: the live listener writes this file, and
    # immutable=1 would read a snapshot that ignores its WAL.
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        for meta, in con.execute("SELECT meta FROM uids WHERE present = 1"):
            try:
                yield json.loads(meta or "{}")
            except ValueError:
                continue
    finally:
        con.close()


def main():
    wanted = {}          # message-id -> set of tags
    for db in maps():
        for m in rows(db):
            mid = (m.get("InternetMessageId") or "").strip("<> \t")
            if not mid:
                continue
            tags = set()
            v = VIEW_TAGS.get(str(m.get("InferenceClassification") or "").lower())
            if v:
                tags.add(v)
            for cat in (m.get("Categories") or []):
                t = CATEGORY_TAGS.get(cat)
                if t:
                    tags.add(t)
            if tags:
                wanted.setdefault(mid, set()).update(tags)

    if not wanted:
        print("nothing to tag (no UID map, or no classified mail)", file=sys.stderr)
        return 0

    # One batch, one notmuch invocation. Each line sets the FULL managed tag
    # state for that message: everything it should have, minus everything it
    # should not, so a reclassification converges in one pass.
    lines = []
    for mid, tags in wanted.items():
        ops = " ".join(f"+{t}" for t in sorted(tags))
        ops += "".join(f" -{t}" for t in sorted(MANAGED - tags))
        lines.append(f"{ops} -- id:{mid}")
    batch = "\n".join(lines) + "\n"

    r = subprocess.run(["notmuch", "tag", "--batch"], input=batch,
                       capture_output=True, text=True)
    # A message-id in the map but not in the index is normal -- mbsync excludes
    # folders, and mail can be newer than the last `notmuch new`. notmuch says
    # nothing about those, so only real failures land on stderr.
    if r.stderr.strip():
        print(r.stderr.strip()[:2000], file=sys.stderr)
    print(f"tagged {len(wanted)} message(s) from {len(maps())} UID map(s)")
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
