#!/usr/bin/env bash
# Does pressing `o` on an open message actually SHOW the message?
#
# The user-visible contract, checked the only way that has proved reliable in
# this work: drive the running aerc and read the pane back. terminal-browser
# currently takes the pane and paints NOTHING -- the process runs, the page
# reports readyState complete, and the pane is empty. A check that asks whether
# the renderer launched would call that a pass, so this one asks whether TEXT
# ARRIVED.
#
# SAFETY, learned the hard way: `o` is safe to send, Enter is NOT. In aerc's
# [view] context Enter is `:reply -a` and has opened a reply composer to a
# newsletter three times. This script sends only `o` and `q`.
#
# Exit 0 = the pane shows the message. 1 = blank or too little text. 2 = could
# not find aerc.
set -u
REPORT=0
[ "${1:-}" = "--report" ] && REPORT=1

exec python3 - "$REPORT" <<'PY'
import json
import subprocess
import sys
import time

REPORT = sys.argv[1] == "1"
MIN_LINES = 8      # a rendered mail is many lines; a blank pane is zero
MIN_LETTERS = 200  # and carries real words, not just chrome


def herdr(*args):
    r = subprocess.run(["herdr", *args], capture_output=True, text=True)
    return r.stdout


def find_aerc():
    """The pane whose terminal title is aerc. Pane IDs change across a herdr
    restart -- w19:pW became w19:p2E when the server was upgraded -- so never
    hard-code one."""
    try:
        panes = json.loads(herdr("pane", "list"))["result"]["panes"]
    except Exception:
        return None, None
    for p in panes:
        try:
            info = json.loads(herdr("pane", "get", p["pane_id"]))["result"]["pane"]
        except Exception:
            continue
        if (info.get("terminal_title_stripped") or "").strip() == "aerc":
            return p["pane_id"], p["tab_id"]
    return None, None


def body(pane):
    out = herdr("pane", "read", pane)
    return [l.rstrip() for l in out.split("\n")[1:] if l.strip()]


pane, tab = find_aerc()
if not pane:
    print("aerc is not running in any herdr pane", file=sys.stderr)
    sys.exit(2)

before = body(pane)
print(f"pane {pane}: {len(before)} lines before")

subprocess.run(["herdr", "pane", "send-keys", pane, "o"], capture_output=True)
time.sleep(10)
after = body(pane)
letters = sum(c.isalpha() for l in after for c in l)
print(f"after `o`: {len(after)} lines, {letters} letters")
for l in after[:4]:
    print(f"   | {l[:100]}")

ok = len(after) >= MIN_LINES and letters >= MIN_LETTERS
print(f"verdict: {'ok' if ok else 'BLANK -- the renderer took the pane and showed nothing'}")

# Always hand the pane back, pass or fail.
subprocess.run(["herdr", "pane", "send-keys", pane, "q"], capture_output=True)
time.sleep(3)
if not body(pane):
    subprocess.run(["herdr", "pane", "send-keys", pane, "q"], capture_output=True)

sys.exit(0 if (REPORT or ok) else 1)
PY
