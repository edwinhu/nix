#!/usr/bin/env python3
"""Toggle Vimium globally on/off by flipping a {pattern:'*', passKeys:''} exclusion
rule in chrome.storage.sync, written through a Vimium content-script isolated world
in any loaded tab (independent of the dormant MV3 service worker)."""
import json, sys, urllib.request, websocket

VIMIUM = "dbepggeogbaibhgnhhndojpepiihcmeb"
PORT = 9222
CONNECT_TIMEOUT = 4  # per-tab; a wedged tab is skipped fast

def http(path):
    return json.load(urllib.request.urlopen(f"http://localhost:{PORT}{path}", timeout=3))

class Tab:
    def __init__(self, ws_url):
        self.ws = websocket.create_connection(ws_url, timeout=CONNECT_TIMEOUT)
        self.ws.settimeout(CONNECT_TIMEOUT)
        self._id = 0
        self.contexts = []  # executionContextCreated payloads seen so far

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

    def enable_runtime(self):
        # Runtime.enable emits executionContextCreated for every existing context
        # (main world + each content-script isolated world). _pump buffers them.
        self.cmd("Runtime.enable")
        # brief extra drain for contexts emitted just after the response
        self.ws.settimeout(0.5)
        try:
            while True:
                r = json.loads(self.ws.recv())
                if r.get("method") == "Runtime.executionContextCreated":
                    self.contexts.append(r["params"]["context"])
        except Exception:
            pass
        self.ws.settimeout(CONNECT_TIMEOUT)

    def eval_in(self, context_id, expr, await_promise=False):
        return self.cmd("Runtime.evaluate", {
            "expression": expr, "contextId": context_id,
            "returnByValue": True, "awaitPromise": await_promise})

    def vimium_context(self):
        for c in self.contexts:
            try:
                r = self.eval_in(c["id"], "(chrome&&chrome.runtime&&chrome.runtime.id)||''")
                if r.get("result", {}).get("value") == VIMIUM:
                    return c["id"]
            except Exception:
                continue
        return None

    def close(self):
        try: self.ws.close()
        except Exception: pass


def toggle_via(tab):
    tab.enable_runtime()
    ctx = tab.vimium_context()
    if ctx is None:
        return None
    read = tab.eval_in(ctx,
        "chrome.storage.sync.get('exclusionRules').then(r=>JSON.stringify(r.exclusionRules||[]))",
        await_promise=True)
    rules = json.loads(read["result"]["value"])
    is_off = any(r.get("pattern") == "*" and r.get("passKeys", "") == "" for r in rules)
    if is_off:  # currently disabled -> remove the rule -> ON
        rules = [r for r in rules if not (r.get("pattern") == "*" and r.get("passKeys", "") == "")]
        state = "ON"
    else:       # currently enabled -> add the disable rule -> OFF
        rules = rules + [{"pattern": "*", "passKeys": ""}]
        state = "OFF"
    w = tab.eval_in(ctx,
        "chrome.storage.sync.set({exclusionRules:%s}).then(()=>'ok')" % json.dumps(rules),
        await_promise=True)
    if w.get("result", {}).get("value") != "ok":
        raise RuntimeError("storage.set failed")
    return state


def nudge(ws_url):
    """Fire a no-op history update in a tab's main world so Vimium re-checks its
    enabled state live (no reload). replaceState(sameState, sameURL) changes
    nothing the page can observe (it does not fire popstate) but triggers
    chrome.webNavigation.onHistoryStateUpdated, which Vimium's background relays
    to the content script as checkEnabledAfterURLChange — its normal SPA-nav
    re-check path. Plain Runtime.evaluate (no Runtime.enable), so wedged tabs
    just time out and are skipped."""
    try:
        w = websocket.create_connection(ws_url, timeout=CONNECT_TIMEOUT)
        w.settimeout(CONNECT_TIMEOUT)
        w.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {
            "expression": "history.replaceState(history.state,'',location.href)",
            "returnByValue": True}}))
        while True:
            r = json.loads(w.recv())
            if r.get("id") == 1:
                break
        w.close()
        return True
    except Exception:
        return False


def main():
    pages = [t for t in http("/json")
             if t.get("type") == "page" and t.get("url", "").startswith(("http://", "https://"))
             and t.get("webSocketDebuggerUrl")]
    if not pages:
        print("vimium-toggle: no open web page to reach Vimium through", file=sys.stderr)
        return 2
    last_err = None
    for t in pages:
        tab = None
        try:
            tab = Tab(t["webSocketDebuggerUrl"])
            state = toggle_via(tab)
        except Exception as e:
            last_err = e
            state = None
        finally:
            if tab:
                tab.close()
        if state is not None:
            # Make it take effect live on every reachable tab (best-effort).
            nudged = sum(nudge(p["webSocketDebuggerUrl"]) for p in pages)
            print(f"Vimium: {state}  ({nudged}/{len(pages)} tabs refreshed live)")
            return 0
    print(f"vimium-toggle: could not reach a Vimium content script "
          f"(last error: {last_err})", file=sys.stderr)
    return 3

if __name__ == "__main__":
    sys.exit(main())
