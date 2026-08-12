#!/usr/bin/env python3
"""Frecency address book over both mail accounts, for aerc's address-book-cmd.

Query mode (what aerc calls) reads ONLY the cache and must stay instant: aerc
runs it synchronously on every <C-o> in a To/Cc/Bcc field. Index mode is the
slow half -- four IMAP round trips -- and is triggered in the background when
the cache goes stale, never inline.

The corpus is envelope metadata, not full headers: `himalaya envelope list`
exposes exactly one recipient per sent message and one sender per received one.
Cc and additional To recipients are therefore INVISIBLE here, and fetching them
would mean a header fetch per message. First-recipient plus inbox-sender covers
the addresses actually typed into a compose field.
"""

import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
    "aerc", "addressbook.tsv",
)

# (account, mailbox, field, weight). An address you have WRITTEN to is a far
# better completion candidate than one that merely wrote to you, hence 5:1 --
# strong enough that a one-off reply outranks a mailing list you receive weekly.
#
# Mailbox ALIASES, not backend-native names: the two accounts are on different
# backends (work on Microsoft Graph, personal on Gmail IMAP) and spell their
# folders differently. `[mailbox.alias]` in the himalaya config is what makes
# `sent` mean `sentitems` on one and `[Gmail]/Sent Mail` on the other.
SOURCES = [
    ("work", "sent", "to", 5.0),
    ("work", "inbox", "from", 1.0),
    ("personal", "sent", "to", 5.0),
    ("personal", "inbox", "from", 1.0),
]

PAGE_SIZE = 500
HALF_LIFE_DAYS = 180.0
STALE_SECONDS = 6 * 3600

OWN = {"ehu@law.virginia.edu", "eddyhu@gmail.com"}
JUNK = re.compile(
    r"(^|[.-])(no-?reply|do-?not-?reply|donotreply|mailer-daemon|postmaster|"
    r"bounce|notifications?|automated|noreply)([.-]|@)",
    re.I,
)


def envelopes(account, mailbox):
    try:
        out = subprocess.run(
            ["himalaya", "envelope", "list", "-a", account, "-m", mailbox,
             "-s", str(PAGE_SIZE), "--json"],
            capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if out.returncode != 0:
        return []
    try:
        # v2 wraps the list in an object; an error is reported as {"error": ...}
        # with exit 0 in some paths, and .get returns [] for that too.
        return json.loads(out.stdout).get("envelopes") or []
    except (json.JSONDecodeError, AttributeError):
        return []


def parties(env, field):
    """The `from`/`to` of a v2 envelope: a LIST of {name, email}.

    v1 gave a single {name, addr} object per field. Both the arity and the
    address key changed, so this is not a rename -- a `to` with several
    recipients now contributes all of them.
    """
    for p in env.get(field) or []:
        addr = ((p or {}).get("email") or "").strip().lower()
        if addr:
            yield addr, ((p or {}).get("name") or "").strip()


def age_days(stamp):
    # v2 emits RFC 3339, e.g. "2026-08-12T17:39:44Z". `fromisoformat` accepts
    # the trailing Z only from 3.11; map it to +00:00 so older builds agree.
    try:
        when = datetime.fromisoformat(
            stamp.replace(" ", "T").replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return 0.0
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return max(0.0, (datetime.now(timezone.utc) - when).total_seconds() / 86400.0)


def index():
    scores, names, seen_at = {}, {}, {}
    for account, mailbox, field, weight in SOURCES:
        for env in envelopes(account, mailbox):
            days = age_days(env.get("date", ""))
            for addr, name in parties(env, field):
                if "@" not in addr or addr in OWN or JUNK.search(addr):
                    continue
                scores[addr] = scores.get(addr, 0.0) + weight * 0.5 ** (days / HALF_LIFE_DAYS)
                # Keep the display name from the most recent message that carried
                # one: names go stale (marriage, title in the display name) and the
                # newest spelling is the one the recipient currently uses.
                if name and name.lower() != addr and days <= seen_at.get(addr, 1e9):
                    names[addr], seen_at[addr] = name, days

    if not scores:
        return False  # every source failed (offline) -- keep the old cache

    ranked = sorted(scores.items(), key=lambda kv: -kv[1])
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = CACHE + ".new"
    with open(tmp, "w") as fh:
        for addr, score in ranked:
            fh.write(f"{addr}\t{names.get(addr, '')}\t{score:.4f}\n")
    os.replace(tmp, CACHE)  # atomic: a query mid-index never sees a partial file
    return True


def refresh_in_background():
    # Detached and fully redirected, or aerc blocks on the inherited stdout pipe
    # until the IMAP fetches finish -- which is the exact latency this avoids.
    try:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--index"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
    except OSError:
        pass


def query(term):
    # Never index inline, not even on a cold cache: a full index is ~75s of IMAP
    # and aerc's completion popup would hang the composer for all of it. A cold
    # cache completes nothing this once and is warm a minute later (the timer
    # also builds it at login).
    if not os.path.exists(CACHE):
        refresh_in_background()
        return
    if time.time() - os.path.getmtime(CACHE) > STALE_SECONDS:
        refresh_in_background()

    term = term.strip().lower()
    hits = []
    try:
        with open(CACHE) as fh:
            for line in fh:
                addr, _, rest = line.rstrip("\n").partition("\t")
                name, _, _score = rest.partition("\t")
                if not term or term in addr or term in name.lower():
                    hits.append((addr, name))
    except OSError:
        return
    # Cache is already frecency-ordered, so slicing preserves the ranking.
    for addr, name in hits[:20]:
        print(f"{addr}\t{name}" if name else addr)


if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "--index":
        sys.exit(0 if index() else 1)
    query(arg)
