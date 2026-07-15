#!/usr/bin/env python3
"""Toggle Vimium for the CURRENT (focused) tab's site.

Chrome exposes no extension enable/disable shortcut and Vimium's only command is
its popup, so this drives Vimium's own mechanism directly: a per-site absolute
exclusion rule ({pattern:"https?://host/*", passKeys:""}) in chrome.storage.sync
— exactly what the popup's "disable" writes. We find the focused tab via
document.hasFocus(), flip that site's rule through a Vimium content-script
isolated world (independent of the dormant MV3 service worker), and nudge just
that tab so it takes effect live (no reload).

Only the focused tab is touched, so it stays fast no matter how many tabs are
open, and idle/wedged tabs never block it."""
import json
import subprocess
import sys
import threading
import time
import urllib.request
from urllib.parse import urlparse
import websocket

VIMIUM = "dbepggeogbaibhgnhhndojpepiihcmeb"
PORT = 9222
TIMEOUT = 1.2
DRAIN = 0.2
FIND_BUDGET = 0.8  # max wait to identify the focused tab


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

    def close(self):
        try: self.ws.close()
        except Exception: pass


def site_pattern(url):
    # Same shape Vimium's popup generates: whole-domain, both schemes.
    return f"https?://{urlparse(url).netloc}/*"


def toggle_site(ws_url, url):
    """Flip the current site's Vimium exclusion + nudge this tab live. Returns
    (state, host)."""
    tab = Tab(ws_url)
    try:
        tab.enable_runtime()
        ctx = tab.vimium_context()
        if ctx is None:
            return None
        pat = site_pattern(url)
        raw = tab.eval(
            "chrome.storage.sync.get('exclusionRules').then(r=>JSON.stringify(r.exclusionRules||[]))",
            ctx=ctx, await_promise=True)
        rules = json.loads(raw)
        disabled = any(r.get("pattern") == pat and r.get("passKeys", "") == "" for r in rules)
        if disabled:  # remove this site's disable rule -> Vimium ON here
            rules = [r for r in rules if not (r.get("pattern") == pat and r.get("passKeys", "") == "")]
            state = "ON"
        else:         # add a disable rule for this site -> Vimium OFF here
            rules = rules + [{"pattern": pat, "passKeys": ""}]
            state = "OFF"
        ok = tab.eval("chrome.storage.sync.set({exclusionRules:%s}).then(()=>'ok')" % json.dumps(rules),
                      ctx=ctx, await_promise=True)
        if ok != "ok":
            raise RuntimeError("storage.set failed")
        # Live re-check without reload: a no-op history update triggers Vimium's
        # own onHistoryStateUpdated -> checkEnabledAfterURLChange path.
        tab.eval("history.replaceState(history.state,'',location.href)")
        return state, urlparse(url).netloc
    finally:
        tab.close()


def find_focused(tabs):
    """Return (url, ws_url) of the focused, visible tab, else None. Probes all
    tabs concurrently (daemon threads) so wedged/idle tabs never block."""
    hit = {}
    lock = threading.Lock()

    def probe(url, ws_url):
        try:
            w = websocket.create_connection(ws_url, timeout=TIMEOUT); w.settimeout(TIMEOUT)
            w.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {
                "expression": "document.hasFocus() && document.visibilityState==='visible'",
                "returnByValue": True}}))
            val = None
            while True:
                r = json.loads(w.recv())
                if r.get("id") == 1:
                    val = r.get("result", {}).get("result", {}).get("value")
                    break
            w.close()
            if val:
                with lock:
                    hit.setdefault("tab", (url, ws_url))
        except Exception:
            pass

    threads = [threading.Thread(target=probe, args=(u, w), daemon=True) for u, w in tabs]
    for t in threads:
        t.start()
    deadline = time.monotonic() + FIND_BUDGET
    while "tab" not in hit and time.monotonic() < deadline and any(t.is_alive() for t in threads):
        time.sleep(0.02)
    return hit.get("tab")


def notify(state, host):
    try:
        subprocess.run(
            ["notify-send", "-a", "vimium", "-u", "low", "-t", "1200",
             "-h", "string:x-canonical-private-synchronous:vimium",
             f"Vimium {state}", f"vim mode {'enabled' if state == 'ON' else 'disabled'} · {host}"],
            timeout=3)
    except Exception:
        pass


def main():
    tabs = [(t["url"], t["webSocketDebuggerUrl"]) for t in http("/json")
            if t.get("type") == "page" and t.get("url", "").startswith(("http://", "https://"))
            and t.get("webSocketDebuggerUrl")]
    if not tabs:
        print("vimium-toggle: no open web page", file=sys.stderr)
        return 2

    focused = find_focused(tabs)
    if focused is None:
        print("vimium-toggle: no focused web page (is a browser tab active?)", file=sys.stderr)
        notify("—", "no active tab")
        return 0
    url, ws_url = focused

    res = toggle_site(ws_url, url)
    if res is None:
        print("vimium-toggle: focused tab has no Vimium content script", file=sys.stderr)
        return 3
    state, host = res
    print(f"Vimium {state} · {host}")
    notify(state, host)
    return 0


if __name__ == "__main__":
    sys.exit(main())
