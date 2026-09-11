#!/usr/bin/env bash
# Does `o` render the mail IN AERC'S OWN PANE?
#
# Three renderers have been measured. Only one paints, and it is not the one
# wanted:
#
#   :exec-tty aerc-mail-tty  -> blank, and NO kitty escape in the stream at all
#   :term aerc-mail-tty      -> blank, same
#   --split right            -> renders, but in a NEW herdr pane beside aerc
#   new ghostty window       -> renders, but leaves the workspace
#
# So the check asserts BOTH halves: the pane must gain a render, and the tab
# must not gain a pane. A split passes the first and fails the second, which is
# the whole point -- "it renders" is not the requirement, "it renders here" is.
#
# Exit 0 = rendered in place. 1 = blank, or it opened somewhere else. 2 = aerc
# not found.
set -u
REPORT=0
[ "${1:-}" = "--report" ] && REPORT=1

exec python3 - "$REPORT" <<'PY'
import json
import os
import subprocess
import sys
import time

REPORT = sys.argv[1] == "1"


def herdr(*a):
    return subprocess.run(["herdr", *a], capture_output=True, text=True).stdout


def panes():
    try:
        return json.loads(herdr("pane", "list"))["result"]["panes"]
    except Exception:
        return []


def find_aerc():
    for p in panes():
        try:
            i = json.loads(herdr("pane", "get", p["pane_id"]))["result"]["pane"]
        except Exception:
            continue
        if (i.get("terminal_title_stripped") or "").strip() == "aerc":
            return p["pane_id"], p["tab_id"]
    return None, None


def text(pane):
    return [l.rstrip() for l in herdr("pane", "read", pane).split("\n")[1:] if l.strip()]


def wait_ready(pane, want, budget=40):
    """Poll until the pane actually shows what is expected. Fixed sleeps are
    how a keystroke landed in a half-started aerc and opened a REPLY COMPOSER
    to a newsletter -- four times. Never send a key on a timer."""
    end = time.time() + budget
    while time.time() < end:
        body = text(pane)
        if any(want in l for l in body):
            return body
        time.sleep(1)
    return None


pane, tab = find_aerc()
if not pane:
    print("aerc is not running in any herdr pane", file=sys.stderr)
    sys.exit(2)

# NORMALISE BY READING FIRST, never by sending a key on assumption. `q` is NOT
# harmless at the message list: there it is bound to `:prompt 'Quit?' quit`, so
# a blind `q` opens a quit prompt and every following keystroke lands in it.
for _ in range(12):
    body = text(pane)
    if not body:                       # a renderer is holding the pane blank
        subprocess.run(["herdr", "pane", "send-keys", pane, "q"], capture_output=True)
    elif any("Subject:" in l for l in body):   # a message view is open
        subprocess.run(["herdr", "pane", "send-keys", pane, "q"], capture_output=True)
    elif any("│" in l for l in body):          # the list: this is the start state
        break
    time.sleep(2)
else:
    print("aerc never reached its message list", file=sys.stderr)
    sys.exit(2)

# Open a message. `o` only -- Enter in [view] is `:reply -a`.
subprocess.run(["herdr", "pane", "send-keys", pane, "o"], capture_output=True)
if not wait_ready(pane, "Subject:"):
    print("no message opened", file=sys.stderr)
    sys.exit(2)

before_panes = len([p for p in panes() if p["tab_id"] == tab])
subprocess.run(["herdr", "pane", "send-keys", pane, "o"], capture_output=True)
time.sleep(14)

# ASK THE BROWSER, NOT THE PANE. herdr composites kitty graphics ITSELF -- its
# config says the flag gates "herdr's own image compositing" -- so a painted
# pane and a blank one both read as zero bytes through `pane read`, and the
# graphics-escape test this check first used could never have worked.
# terminal-browser's own `ls --json` reports, per instance, the pane it holds
# and whether it split: splitDir=None with aerc's pane id is exactly "it
# rendered here".
tb = os.path.expanduser("~/.local/share/terminal-browser/app/bin/terminal-browser")
inplace = False
try:
    out = subprocess.run([tb, "ls", "--all", "--json"], capture_output=True, text=True, timeout=15)
    if out.returncode == 0 and out.stdout.strip():
        for b in json.loads(out.stdout).get("browsers", []):
            if (b.get("pane") or {}).get("pane") == pane and not b.get("splitDir"):
                inplace = True
except Exception:
    pass
raw = herdr("pane", "read", pane, "--format", "ansi")
body = text(pane)
after_panes = len([p for p in panes() if p["tab_id"] == tab])
graphics = inplace or "\x1b_G" in raw or "\x1bPq" in raw
letters = sum(c.isalpha() for l in body for c in l)

print(f"panes in tab: {before_panes} -> {after_panes} (must not grow)")
print(f"took the pane in place (browser ls): {inplace}")
print(f"pane text: {len(body)} lines, {letters} letters")

same_pane = after_panes == before_panes
rendered = graphics or letters >= 200
ok = same_pane and rendered
why = []
if not same_pane:
    why.append("opened a NEW pane")
if not rendered:
    why.append("nothing painted")
print("verdict:", "ok" if ok else "FAIL: " + ", ".join(why))

# TEARDOWN MUST ACTUALLY FREE THE PANE, or the next run finds no message list
# and exits 2 -- which looks like "aerc is gone" rather than "the last run left
# a browser sitting on it". `q` is not always honoured by the in-place
# instance, so fall back to killing the process that holds this pane.
subprocess.run(["herdr", "pane", "send-keys", pane, "q"], capture_output=True)
time.sleep(3)
if not text(pane):
    try:
        out = subprocess.run([tb, "ls", "--all", "--json"], capture_output=True, text=True, timeout=15)
        for b in json.loads(out.stdout).get("browsers", []):
            if (b.get("pane") or {}).get("pane") == pane and b.get("pid"):
                subprocess.run(["kill", "-TERM", str(b["pid"])], capture_output=True)
    except Exception:
        pass
    time.sleep(3)

sys.exit(0 if (REPORT or ok) else 1)
PY
