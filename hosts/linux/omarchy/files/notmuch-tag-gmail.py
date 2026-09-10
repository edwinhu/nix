#!/usr/bin/env python3
"""Gmail's split-inbox vocabulary as notmuch tags, over IMAP.

The category tabs are NOT reachable as labels: `X-GM-LABELS` comes back empty
for a message Gmail files under Promotions, and Gmail offers no category
mailboxes over IMAP either -- both measured. They ARE reachable as a SERVER-SIDE
SEARCH: `X-GM-RAW category:updates` runs Gmail's own query engine and returns
the matching sequence numbers.

That is the whole reason this is cheap. One search per view returns a set;
fetching the Message-IDs for the union is one more command. The alternative --
Gmail's REST API -- costs one `messages.get` per message, which is 6,000+
requests and exceeds the per-minute quota the account shares with gws and the
push receiver.

Nothing here classifies anything. Gmail decides; this records the verdict
against the id notmuch indexes by.
"""
import collections
import imaplib
import re
import subprocess
import sys

ACCOUNT = "eddyhu@gmail.com"
TOKEN_CMD = ["ortie", "-a", "google", "token", "show"]

# Gmail search -> notmuch tag. The tabs plus the importance marker, which is
# the one Gmail signal that is neither an IMAP flag nor a folder: starred
# arrives as \Flagged and every user label arrives as its own folder, so
# neither needs anything from here.
QUERIES = {
    "primary": "category:primary",
    "updates": "category:updates",
    "promotions": "category:promotions",
    "social": "category:social",
    "forums": "category:forums",
    "important": "is:important",
}
MANAGED = set(QUERIES)

# imaplib's default line cap is 10k, and a search over a 6k-message mailbox
# answers with one very long line of sequence numbers.
imaplib.IMAP4.MAXLINE = 10_000_000


def connect():
    tok = subprocess.run(TOKEN_CMD, capture_output=True, text=True).stdout.strip()
    if not tok:
        sys.exit("no Google token from ortie")
    m = imaplib.IMAP4_SSL("imap.gmail.com")
    m.authenticate("XOAUTH2", lambda _=None: f"user={ACCOUNT}\1auth=Bearer {tok}\1\1".encode())
    m.select("INBOX", readonly=True)   # readonly: this must never write to Gmail
    return m


def main():
    m = connect()
    try:
        # 1. one server-side search per view: sequence numbers, not messages.
        seqs = {}
        for tag, q in QUERIES.items():
            typ, d = m.search(None, "X-GM-RAW", f'"{q}"')
            if typ != "OK":
                print(f"search failed for {q}: {typ}", file=sys.stderr)
                continue
            seqs[tag] = set((d[0] or b"").split())

        wanted = collections.defaultdict(set)   # seq -> tags
        for tag, s in seqs.items():
            for n in s:
                wanted[n].add(tag)
        if not wanted:
            print("no messages matched any view", file=sys.stderr)
            return 0

        # 2. ONE fetch for the Message-IDs of everything that matched. Sequence
        #    numbers are only meaningful inside this session, so the mapping has
        #    to happen before logout.
        ordered = sorted(wanted, key=lambda b: int(b))
        ids = {}
        CHUNK = 2000
        for i in range(0, len(ordered), CHUNK):
            part = b",".join(ordered[i:i + CHUNK]).decode()
            typ, resp = m.fetch(part, "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
            if typ != "OK":
                continue
            for item in resp:
                if not isinstance(item, tuple):
                    continue
                head = item[0].decode("utf-8", "replace")
                body = item[1].decode("utf-8", "replace")
                sm = re.match(rb"^(\d+)", item[0]) or re.match(r"^(\d+)", head)
                mm = re.search(r"Message-ID:\s*<([^>]+)>", body, re.I)
                if not sm or not mm:
                    continue
                seq = sm.group(1) if isinstance(sm.group(1), bytes) else sm.group(1).encode()
                ids[seq] = mm.group(1).strip()
    finally:
        try:
            m.logout()
        except Exception:
            pass

    # 3. one notmuch batch. Each line states the FULL managed tag set for that
    #    message, so a recategorised message converges rather than accumulating.
    lines = []
    for seq, tags in wanted.items():
        mid = ids.get(seq)
        if not mid:
            continue        # not fetched, or no Message-ID: never tag `id:` empty
        ops = " ".join(f"+{t}" for t in sorted(tags))
        ops += "".join(f" -{t}" for t in sorted(MANAGED - tags))
        lines.append(f"{ops} -- id:{mid}")
    if not lines:
        print("nothing to tag", file=sys.stderr)
        return 0
    r = subprocess.run(["notmuch", "tag", "--batch"], input="\n".join(lines) + "\n",
                       capture_output=True, text=True)
    if r.stderr.strip():
        print(r.stderr.strip()[:2000], file=sys.stderr)
    counts = {t: len(s) for t, s in sorted(seqs.items())}
    print(f"tagged {len(lines)} message(s): {counts}")
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
