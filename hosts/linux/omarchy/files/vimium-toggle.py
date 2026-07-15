#!/usr/bin/env python3
"""Global Vimium on/off toggle, resting state OFF (opt-in "vim mode").

Chrome exposes no extension enable/disable shortcut and Vimium's only command is
its popup, so this drives Vimium's own mechanism directly: a global absolute
exclusion rule ({pattern:"*", passKeys:""}) in chrome.storage.sync disables
Vimium everywhere by default; the toggle removes it (ON) / re-adds it (OFF).
Vimium is deny-list only (no allow-list), so per-page opt-in over a default-off
isn't expressible — this is a whole-browser vim-mode switch.

Applying it live without a reload: Vimium re-reads its enabled state in
checkIfEnabledForUrl(), which runs on the window `focus` event (onFocus). It does
NOT re-run on a same-URL history change (checkEnabledAfterURLChange bails when the
URL is unchanged), so a replaceState nudge does nothing — that was the original
"just shows the toast, nothing changes until I refocus" bug. Instead we fire a
genuine TRUSTED focus event via CDP Emulation.setFocusEmulationEnabled (on then
off): it reaches Vimium's forTrusted onFocus handler and triggers the re-check —
the same code path as the user manually refocusing the window, but without
touching the URL or switching tabs.

We target the focused tab, found via Hyprland's active window (Chrome on Wayland
doesn't report document.hasFocus() reliably and every PWA window reads
visibility 'visible', so the compositor is the ground truth), mapped to a CDP tab
by PWA host (window class chrome-<host>__…) or by title. The MV3 service worker
is usually dormant, so we never rely on it."""
import json
import os
import re
import socket
import subprocess
import sys
import urllib.request
from urllib.parse import urlparse
import websocket

VIMIUM = "dbepggeogbaibhgnhhndojpepiihcmeb"
PORT = 9222
TIMEOUT = 1.5
DRAIN = 0.2


def http(path):
    return json.load(urllib.request.urlopen(f"http://localhost:{PORT}{path}", timeout=2))


class Tab:
    def __init__(self, ws_url):
        self.ws = websocket.create_connection(ws_url, timeout=TIMEOUT)
        self.ws.settimeout(TIMEOUT)
        self._id = 0
        self.contexts = []

    def _pump(self, want_id):
        while True:
            r = json.loads(self.ws.recv())
            if r.get("method") == "Runtime.executionContextCreated":
                self.contexts.append(r["params"]["context"])
            elif r.get("id") == want_id:
                if "error" in r:
                    raise RuntimeError(r["error"])
                return r["result"]

    def cmd(self, method, params=None):
        self._id += 1
        self.ws.send(json.dumps({"id": self._id, "method": method, "params": params or {}}))
        return self._pump(self._id)

    def eval(self, expr, ctx=None, await_promise=False):
        p = {"expression": expr, "returnByValue": True, "awaitPromise": await_promise}
        if ctx is not None:
            p["contextId"] = ctx
        return self.cmd("Runtime.evaluate", p).get("result", {}).get("value")

    def enable_runtime(self):
        self.cmd("Runtime.enable")
        self.ws.settimeout(DRAIN)
        try:
            while True:
                r = json.loads(self.ws.recv())
                if r.get("method") == "Runtime.executionContextCreated":
                    self.contexts.append(r["params"]["context"])
        except Exception:
            pass
        self.ws.settimeout(TIMEOUT)

    def vimium_context(self):
        for c in self.contexts:
            try:
                if self.eval("(chrome&&chrome.runtime&&chrome.runtime.id)||''", ctx=c["id"]) == VIMIUM:
                    return c["id"]
            except Exception:
                continue
        return None

    def focus_nudge(self):
        # Fire a trusted window focus -> Vimium onFocus -> checkIfEnabledForUrl.
        self.cmd("Emulation.setFocusEmulationEnabled", {"enabled": True})
        self.cmd("Emulation.setFocusEmulationEnabled", {"enabled": False})

    def close(self):
        try: self.ws.close()
        except Exception: pass


def hypr(cmd):
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    xdg = os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000")
    if not sig:
        return None
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(1)
        s.connect(f"{xdg}/hypr/{sig}/.socket.sock")
        s.sendall(("j/" + cmd).encode())
        buf = b""
        while True:
            d = s.recv(65536)
            if not d:
                break
            buf += d
        s.close()
        return json.loads(buf)
    except Exception:
        return None


def find_focused(tabs):
    """Map Hyprland's active window to a CDP tab: PWA host from the window class
    (chrome-<host>__…), else exact/contains title match. Returns tab dict or None."""
    aw = hypr("activewindow")
    if not aw:
        return None
    cls = aw.get("class", "") or ""
    wtitle = aw.get("title", "") or ""
    m = re.match(r"chrome-(.+?)__", cls)
    if m:
        host = m.group(1)
        for t in tabs:
            if urlparse(t["url"]).netloc == host:
                return t
    title = wtitle
    for suf in (" - Chromium", " — Chromium"):
        if title.endswith(suf):
            title = title[:-len(suf)]
            break
    for t in tabs:
        if t.get("title", "") == title:
            return t
    for t in tabs:
        if t.get("title") and t["title"] in wtitle:
            return t
    return None


def toggle_rule(tab, ctx):
    """Flip the global disable rule in chrome.storage.sync. Returns state."""
    raw = tab.eval(
        "chrome.storage.sync.get('exclusionRules').then(r=>JSON.stringify(r.exclusionRules||[]))",
        ctx=ctx, await_promise=True)
    rules = json.loads(raw)
    off = any(r.get("pattern") == "*" and r.get("passKeys", "") == "" for r in rules)
    if off:  # remove the global disable rule -> vim mode ON
        rules = [r for r in rules if not (r.get("pattern") == "*" and r.get("passKeys", "") == "")]
        state = "ON"
    else:    # add the global disable rule -> vim mode OFF
        rules = rules + [{"pattern": "*", "passKeys": ""}]
        state = "OFF"
    ok = tab.eval("chrome.storage.sync.set({exclusionRules:%s}).then(()=>'ok')" % json.dumps(rules),
                  ctx=ctx, await_promise=True)
    if ok != "ok":
        raise RuntimeError("storage.set failed")
    return state


def notify(state):
    label = {"ON": ("Vimium ON", "vim mode enabled"),
             "OFF": ("Vimium OFF", "vim mode disabled")}.get(state, ("Vimium", state))
    try:
        subprocess.run(
            ["notify-send", "-a", "vimium", "-u", "low", "-t", "1200",
             "-h", "string:x-canonical-private-synchronous:vimium", *label],
            timeout=3)
    except Exception:
        pass


def main():
    tabs = [t for t in http("/json")
            if t.get("type") == "page" and t.get("url", "").startswith(("http://", "https://"))
            and t.get("webSocketDebuggerUrl")]
    if not tabs:
        print("vimium-toggle: no open web page", file=sys.stderr)
        return 2

    # Prefer the focused tab (so it flips where the user is looking); fall back to
    # any other reachable tab so the global rule still flips if the focused tab is
    # wedged (other tabs then pick it up on their next focus/navigation).
    focused = find_focused(tabs)
    order = ([focused] if focused else []) + [t for t in tabs if t is not focused]

    for t in order:
        tab = None
        try:
            tab = Tab(t["webSocketDebuggerUrl"])
            tab.enable_runtime()
            ctx = tab.vimium_context()
            if ctx is None:
                continue
            state = toggle_rule(tab, ctx)
            try:
                tab.focus_nudge()  # live re-check on this tab, no reload
            except Exception:
                pass
            print(f"Vimium {state}")
            notify(state)
            return 0
        except Exception:
            continue
        finally:
            if tab:
                tab.close()

    print("vimium-toggle: could not reach a Vimium content script", file=sys.stderr)
    notify("—")
    return 3


if __name__ == "__main__":
    sys.exit(main())
