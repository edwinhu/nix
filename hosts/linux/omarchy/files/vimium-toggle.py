#!/usr/bin/env python3
"""Global Vimium on/off toggle, resting state OFF (opt-in "vim mode").

Chrome exposes no extension enable/disable shortcut and Vimium's only command is
its popup, so this drives Vimium's own mechanism directly: a global absolute
exclusion rule ({pattern:"*", passKeys:""}) in chrome.storage.sync disables
Vimium everywhere by default; the toggle removes it (ON) / re-adds it (OFF).
Vimium is deny-list only (no allow-list), so per-page opt-in over a default-off
isn't expressible — this is a whole-browser vim-mode switch.

Applying it live without a reload: call Vimium's own checkIfEnabledForUrl()
directly. Vimium's content scripts are CLASSIC scripts (not modules), so its
top-level declarations (async function checkIfEnabledForUrl, let
isEnabledForUrl) live in the isolated world's global scope — and
Runtime.evaluate with that world's contextId shares that scope. Calling it
performs the initializeFrame round trip (waking a dormant MV3 worker) and
re-applies the result exactly as a real focus/navigation re-check would
(isEnabledForUrl, normalMode.setPassKeys, HUD.hide). We poll until
isEnabledForUrl reflects the state we just wrote, because the worker's
storage.onChanged/Settings cache can lag the write. Verified live via CDP:
trusted 'f' keydown yields hint markers after ON and none after OFF, with no
reload and no focus change. (Focus emulation is NOT reliable here: it only
fires a focus event when it changes focus state, so it is a no-op on the
already-focused tab. A same-URL history nudge fails too — Vimium bails out
when the URL is unchanged.)

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
import threading
import time
import urllib.request
from urllib.parse import urlparse
import websocket

VIMIUM = "dbepggeogbaibhgnhhndojpepiihcmeb"
PORT = 9222
TIMEOUT = 1.5
DRAIN = 0.2
APPLY_TIMEOUT_MS = 2500
LOG_PATH = os.path.expanduser("~/.cache/vimium-toggle.log")


def log_run(record):
    """Best-effort: append one JSON line describing this run. Never raises — the
    toggle must work even if logging can't. Lets us see, after a real Hyper+V
    press, exactly which tab was targeted vs. where the user actually was."""
    try:
        record["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a") as f:
            f.write(json.dumps(record, default=str) + "\n")
    except Exception:
        pass


def http(path):
    return json.load(urllib.request.urlopen(f"http://localhost:{PORT}{path}", timeout=2))


class Tab:
    def __init__(self, ws_url, timeout=TIMEOUT):
        self.ws = websocket.create_connection(ws_url, timeout=timeout)
        self.ws.settimeout(timeout)
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

    def vimium_context(self, diag=None):
        # There is a Vimium isolated world for every frame. The window focus
        # listener which controls the visible tab lives in the top frame, so do
        # not use whichever executionContextCreated event happened to arrive
        # first (it is commonly an iframe on long-lived/PWA pages).
        frame_id = self.cmd("Page.getFrameTree")["frameTree"]["frame"]["id"]
        if diag is not None:
            diag["top_frame_id"] = frame_id
            diag["n_contexts"] = len(self.contexts)
        for c in self.contexts:
            try:
                aux = c.get("auxData", {})
                if (aux.get("frameId") == frame_id and
                        self.eval("(chrome&&chrome.runtime&&chrome.runtime.id)||''",
                                  ctx=c["id"]) == VIMIUM):
                    if diag is not None:
                        diag["ctx_origin"] = c.get("origin")
                    return c["id"]
            except Exception:
                continue
        return None

    def apply_state(self, ctx, enabled):
        """Re-apply enabled state live by invoking Vimium's own re-check.

        checkIfEnabledForUrl() is a top-level classic-script declaration in the
        content-script isolated world, so it is directly callable from a CDP
        evaluation in that context. Awaiting it and re-reading isEnabledForUrl
        both confirms the background observed the new storage and guarantees
        the frontend state (isEnabledForUrl, passKeys, HUD) was re-applied —
        the polling covers the worker's storage.onChanged propagation lag."""
        expected = "true" if enabled else "false"
        expr = """(async()=>{
          if (typeof checkIfEnabledForUrl!=='function') return 'no-fn';
          const deadline=performance.now()+%d;
          while(performance.now()<deadline){
            try {
              await checkIfEnabledForUrl();
              if (isEnabledForUrl===%s) return true;
            } catch (_) {}
            await new Promise(resolve=>setTimeout(resolve,50));
          }
          return false;
        })()""" % (APPLY_TIMEOUT_MS, expected)
        old_timeout = self.ws.gettimeout()
        self.ws.settimeout(APPLY_TIMEOUT_MS / 1000 + 1.0)
        try:
            r = self.eval(expr, ctx=ctx, await_promise=True)
            if r is not True:
                # r is 'no-fn' or False (timeout). Surface it verbatim so the
                # log distinguishes "wrong world / not Vimium" from "worker lag".
                raise RuntimeError(f"apply={r!r}: re-check did not reach new state")
            # Best-effort: nudge Vimium's worlds in subframes too (their key
            # handling is per-frame). The background is synced now, so a
            # fire-and-forget call suffices; never let a wedged iframe fail us.
            self.ws.settimeout(TIMEOUT)
            for c in self.contexts:
                if c["id"] == ctx:
                    continue
                try:
                    self.eval(
                        "typeof checkIfEnabledForUrl==='function'"
                        "&&(checkIfEnabledForUrl(),true)", ctx=c["id"])
                except Exception:
                    continue
        finally:
            self.ws.settimeout(old_timeout)

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


def find_focused(tabs, diag=None):
    """Map Hyprland's active window to a CDP tab: PWA host from the window class
    (chrome-<host>__…), else exact/contains title match. Returns the tab dict or
    None. `diag`, if given, is a dict populated with the activewindow and the
    match reason/ambiguity for the durable log — CDP /json exposes no active-tab
    marker, so this heuristic is the whole ballgame and must be observable."""
    def note(**kw):
        if diag is not None:
            diag.update(kw)
    aw = hypr("activewindow")
    if not aw:
        note(activewindow=None, match="no-activewindow")
        return None
    cls = aw.get("class", "") or ""
    wtitle = aw.get("title", "") or ""
    note(activewindow={"class": cls, "title": wtitle})
    m = re.match(r"chrome-(.+?)__", cls)
    if m:
        host = m.group(1)
        hits = [t for t in tabs if urlparse(t["url"]).netloc == host]
        if hits:
            # Multiple live tabs of the same PWA host are possible; the PWA
            # window shows exactly one, but /json can't say which. Flag it.
            note(match="host", host=host, ambiguous=len(hits) > 1,
                 candidates_matched=[t["id"] for t in hits])
            return hits[0]
        note(match="host-miss", host=host)
        return None
    title = wtitle
    for suf in (" - Chromium", " — Chromium"):
        if title.endswith(suf):
            title = title[:-len(suf)]
            break
    exact = [t for t in tabs if t.get("title", "") == title]
    if exact:
        note(match="title-exact", stripped_title=title,
             ambiguous=len(exact) > 1, candidates_matched=[t["id"] for t in exact])
        return exact[0]
    contains = [t for t in tabs if t.get("title") and t["title"] in wtitle]
    if contains:
        # Loose fallback: a tab whose title is a substring of the window title.
        # Genuinely fragile (short/common titles can false-match); always flag.
        note(match="title-contains", stripped_title=title,
             ambiguous=len(contains) > 1, candidates_matched=[t["id"] for t in contains])
        return contains[0]
    note(match="no-match", stripped_title=title)
    return None


def enabled_for_url(rules, url):
    """Replicate Vimium's exclusions.getRule verdict: a URL is enabled unless an
    ABSOLUTE rule (empty passKeys) matches. Patterns are raw regexes anchored
    with ^…$ after expanding * to .* (Vimium does no other escaping). Rules with
    passKeys only limit keys — the frame still counts as enabled."""
    for r in rules:
        if r.get("pattern") and not r.get("passKeys", ""):
            try:
                if re.search("^" + r["pattern"].replace("*", ".*") + "$", url):
                    return False
            except re.error:
                continue
    return True


def toggle_rule(tab, ctx):
    """Flip the global disable rule in chrome.storage.sync.
    Returns (state, new_rules)."""
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
    return state, rules


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


def _apply_worker(t, shared, lock, write_done, attempts):
    """Reach a tab's top-frame Vimium world; the first worker to get there flips
    the global rule (under lock), then EVERY worker calls Vimium's own re-check
    for its tab. Applying to all reachable tabs means the tab the user is looking
    at re-checks live no matter which one it is — no fragile focused-tab
    detection, which was the production bug."""
    att = {"id": t["id"], "url": t["url"], "title": t.get("title")}
    tab = None
    try:
        tab = Tab(t["webSocketDebuggerUrl"], timeout=TIMEOUT)
        tab.enable_runtime()
        cdiag = {}
        ctx = tab.vimium_context(diag=cdiag)
        att.update(cdiag)
        if ctx is None:
            att["ctx"] = "none"
            return
        att["ctx"] = "found"
        with lock:
            if "rules" not in shared:
                state, rules = toggle_rule(tab, ctx)
                shared["state"] = state
                shared["rules"] = rules
                write_done.set()
                att["wrote"] = True
        # Wait until the rule has actually been written before re-checking, so no
        # tab observes stale settings.
        write_done.wait(timeout=3.0)
        rules = shared.get("rules")
        if rules is None:
            att["apply"] = "no-write"
            return
        url = tab.eval("location.href", ctx=ctx) or t["url"]
        att["applied_url"] = url
        enabled = enabled_for_url(rules, url)
        att["expect_enabled"] = enabled
        tab.apply_state(ctx, enabled)  # calls Vimium checkIfEnabledForUrl() directly
        att["apply"] = "ok"
    except Exception as e:
        att["error"] = str(e)
        att.setdefault("connect", f"fail: {e}")
    finally:
        attempts.append(att)  # list.append is atomic under the GIL
        if tab:
            tab.close()


def main():
    rec = {"attempts": []}
    tabs = [t for t in http("/json")
            if t.get("type") == "page" and t.get("url", "").startswith(("http://", "https://"))
            and t.get("webSocketDebuggerUrl")]
    if not tabs:
        print("vimium-toggle: no open web page", file=sys.stderr)
        rec["result"] = "no-web-page"
        log_run(rec)
        return 2

    shared = {}
    lock = threading.Lock()
    write_done = threading.Event()
    threads = [threading.Thread(target=_apply_worker,
                                args=(t, shared, lock, write_done, rec["attempts"]),
                                daemon=True)
               for t in tabs]
    for th in threads:
        th.start()
    # Bounded: responsive tabs (incl. the user's focused one) finish in ~1-3s;
    # wedged/idle tabs that never answer CDP are abandoned at the deadline.
    deadline = time.monotonic() + 5.0
    for th in threads:
        th.join(max(0.0, deadline - time.monotonic()))

    state = shared.get("state")
    if state is None:
        print("vimium-toggle: could not reach a Vimium content script", file=sys.stderr)
        notify("\u2014")
        rec["result"] = "no-vimium-content-script"
        rec["rc"] = 3
        log_run(rec)
        return 3

    applied = sum(1 for a in rec["attempts"] if a.get("apply") == "ok")
    rec["result"] = "toggled-all"
    rec["applied_live"] = applied
    rec["n_tabs"] = len(tabs)
    rec["rc"] = 0
    print(f"Vimium {state}")
    notify(state)
    log_run(rec)
    return 0


if __name__ == "__main__":
    sys.exit(main())
