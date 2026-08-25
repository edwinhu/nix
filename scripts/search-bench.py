#!/usr/bin/env python3
"""Time IMAP SEARCH TEXT against a mail-bridge archive listener.

usage: search-bench.py <binary> <corpus.sqlite3> <account> <provider> <port> <term>...
Starts `archive account serve` on <port>, runs each SEARCH TEXT <term> once,
prints one JSON object, kills the listener.
"""
import json, socket, subprocess, sys, time, os, signal

binary, corpus, account, provider, port, *terms = sys.argv[1:]
port = int(port)

proc = subprocess.Popen(
    [binary, "archive", "account", "serve", "--state", corpus, "--account", account,
     "--provider", provider, "--port", str(port), "--stale-after-ms", "999999999999"],
    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
try:
    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=2); s.close(); break
        except OSError:
            if proc.poll() is not None:
                sys.exit("listener died: " + proc.stderr.read().decode()[:2000])
            time.sleep(0.25)
    else:
        sys.exit("listener never bound")

    s = socket.create_connection(("127.0.0.1", port), timeout=600)
    f = s.makefile("rwb")

    def cmd(tag, line):
        f.write(f"{tag} {line}\r\n".encode()); f.flush()
        out = []
        while True:
            resp = f.readline()
            if not resp:
                raise RuntimeError("connection closed")
            out.append(resp.decode(errors="replace").rstrip("\r\n"))
            if out[-1].startswith(tag + " "):
                return out

    f.readline()  # greeting
    cmd("a1", "LOGIN bench bench")
    cmd("a2", "SELECT INBOX")
    results = {}
    for i, term in enumerate(terms):
        t0 = time.perf_counter()
        lines = cmd(f"s{i}", f"SEARCH TEXT {term}")
        elapsed = time.perf_counter() - t0
        hits = 0
        for ln in lines:
            if ln.startswith("* SEARCH"):
                hits = len(ln.split()) - 2
        status = lines[-1].split(" ", 2)[1]
        results[term] = {"seconds": round(elapsed, 4), "hits": hits, "status": status}
    cmd("z1", "LOGOUT")
    print(json.dumps({"binary": binary, "results": results}, indent=2))
finally:
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception:
        pass
