#!/usr/bin/env bash
# Photograph aerc before and after `o`, and prove the photograph is LIVE.
#
# The instrument comes first because the old one lied. The ghostty window sits
# off-screen (x=-1250 in a scrolling layout), an unmapped window is not
# repainted, and `grim -T <stableId>` then hands back the last committed buffer
# -- three captures around a cursor move came back byte-identical. Every
# screenshot taken that way is a frozen frame, and a frozen frame reads exactly
# like "the renderer painted nothing".
#
# So: float the window on-screen, prove capture tracks reality by moving the
# cursor and requiring the hash to change, and only then shoot before/after.
# If the liveness probe fails the run aborts -- no picture is better than a
# stale one presented as evidence.
set -u
OUT=${1:-$PWD/o-shot}
mkdir -p "$OUT"
exec python3 - "$OUT" <<'PY'
import hashlib, json, subprocess, sys, time

OUT = sys.argv[1]
sh = lambda *a: subprocess.run(a, capture_output=True, text=True).stdout
h = lambda f: hashlib.sha256(open(f, "rb").read()).hexdigest()[:12]
def hypr(cmd): return sh("hyprctl", "dispatch", cmd)
def herdr(*a): return sh("herdr", *a)

def workspace_of(pane):
    """herdr titles a window after the WORKSPACE LABEL, not the tab. Matching
    the title against "aerc" therefore rejects the window that is displaying
    aerc -- w19 is labelled "assistant" and its active tab IS aerc's. The
    correct test is: the workspace holding aerc's tab must have that tab
    ACTIVE, and the window must be titled with that workspace's label."""
    ws = pane.split(":")[0]
    raw = herdr("workspace", "get", ws)
    info = json.loads(raw[raw.index("{"):])["result"]["workspace"]
    return info["label"], info["active_tab_id"]


def win(pane, tab):
    label, active_tab = workspace_of(pane)
    ghostty = [c for c in json.loads(sh("hyprctl", "clients", "-j"))
               if c.get("class") == "com.mitchellh.ghostty"]
    if not ghostty:
        sys.exit("no ghostty window at all")
    if active_tab != tab:
        sys.exit(f"ABORT: workspace {label!r} is showing tab {active_tab}, not "
                 f"aerc's {tab}. Nothing is rendering aerc, so no capture can "
                 "contain it.")
    for c in ghostty:
        if label and label.lower() in (c.get("title") or "").lower():
            return c
    titles = ", ".join(repr(c.get("title")) for c in ghostty)
    sys.exit(f"ABORT: no window is displaying workspace {label!r} (open: {titles}).")


def aerc_pane():
    for p in json.loads(herdr("pane", "list"))["result"]["panes"]:
        i = json.loads(herdr("pane", "get", p["pane_id"]))["result"]["pane"]
        if (i.get("terminal_title_stripped") or "").strip() == "aerc":
            return p["pane_id"], p["tab_id"]
    sys.exit("aerc is not running in any herdr pane")

def body(p):
    return [l.rstrip() for l in herdr("pane", "read", p).split("\n")[1:] if l.strip()]

def wait_for(p, want, budget=40):
    end = time.time() + budget
    while time.time() < end:
        b = body(p)
        if any(want in l for l in b):
            return b
        time.sleep(1)
    return None

pane, tab = aerc_pane()
w = win(pane, tab); addr = "address:" + w["address"]; sid = str(w["stableId"])
print(f"capturing window {w['title']!r} (stableId {w['stableId']}) showing {tab}")
restore = not w["floating"]
def shot(name):
    path = f"{OUT}/{name}.png"
    subprocess.run(["grim", "-T", sid, path], capture_output=True)
    return path, h(path)

# 1. ON-SCREEN. An off-screen window is never repainted and grim returns a
#    stale buffer; nothing below is meaningful until this holds.
# hyprctl dispatch parses its argument as LUA on this build: it wraps the text
# as hl.dispatch(<text>), so every `dispatch setfloating address:0x..` spelling
# fails with a Lua syntax error and changes nothing. The dispatchers live under
# hl.dsp.* and take a table. Errors go to stdout with exit 0, so an unchecked
# call looks like it worked -- which is how a whole evening of "focus didn't
# move it" was really "the command never ran".
hypr("hl.dsp.window.float{window='%s'}" % addr)
time.sleep(1)
hypr("hl.dsp.window.bring_to_top()")
time.sleep(3)
at = [c for c in json.loads(sh("hyprctl", "clients", "-j")) if c["address"] == w["address"]][0]
print(f"window at {at['at']} size {at['size']} floating={at['floating']}")
if at["at"][0] < 0 or at["at"][1] < 0:
    sys.exit(f"ABORT: window is still off-screen at {at['at']}; it will not repaint "
             "and every capture would be a stale buffer.")

# 2. LIVENESS. Move the cursor; the picture MUST change. This is the check the
#    old screenshots never had, and it is why they were believed.
_, a = shot("probe-a")
subprocess.run(["herdr", "pane", "send-keys", pane, "j"], capture_output=True); time.sleep(2)
_, b = shot("probe-b")
subprocess.run(["herdr", "pane", "send-keys", pane, "k"], capture_output=True); time.sleep(2)
print(f"liveness probe: {a} -> {b}")
if a == b:
    sys.exit("ABORT: capture is STALE (a cursor move did not change the pixels). "
             "Any before/after taken now would be a frozen frame, not evidence.")
print("liveness probe: LIVE")

# 3. Normalise by READING, never by sending a key on assumption. In [messages]
#    `q` is bound to `:prompt 'Quit?' quit`, so a blind `q` opens a prompt and
#    every later keystroke lands in it.
for _ in range(12):
    cur = body(pane)
    if not cur or any("Subject:" in l for l in cur):
        subprocess.run(["herdr", "pane", "send-keys", pane, "q"], capture_output=True)
    elif any("│" in l for l in cur):
        break
    time.sleep(2)
else:
    sys.exit("aerc never reached its message list")

# 4. BEFORE: a message open in aerc's own renderer. `o` only -- Enter in [view]
#    is `:reply -a` and has opened reply composers to newsletters.
subprocess.run(["herdr", "pane", "send-keys", pane, "o"], capture_output=True)
if not wait_for(pane, "Subject:"):
    sys.exit("no message opened")
time.sleep(2)
before_path, before_h = shot("BEFORE")
before_panes = len([p for p in json.loads(herdr("pane", "list"))["result"]["panes"] if p["tab_id"] == tab])

# 5. AFTER: press `o` again, the thing under test.
subprocess.run(["herdr", "pane", "send-keys", pane, "o"], capture_output=True)
time.sleep(16)
after_path, after_h = shot("AFTER")
after_panes = len([p for p in json.loads(herdr("pane", "list"))["result"]["panes"] if p["tab_id"] == tab])

print(f"BEFORE {before_path} {before_h}")
print(f"AFTER  {after_path} {after_h}")
print(f"panes in tab: {before_panes} -> {after_panes}")
print("the two frames differ" if before_h != after_h else
      "IDENTICAL -- `o` changed nothing on screen")
print()
print("SEND THESE TO THE USER:")
print(f"  {before_path}")
print(f"  {after_path}")

subprocess.run(["herdr", "pane", "send-keys", pane, "q"], capture_output=True)
# Deliberately NOT restored to its off-screen slot: there it cannot be
# photographed at all, which is the condition this script exists to escape.
PY
