"""Behaviour tests for the preview-server reaping rules in preview-reap.py.

These spawn REAL processes in their own session (the same setsid semantics
preview.sh uses) and let the reaper's own main() decide their fate, because
the bug being fixed is entirely about which live processes get selected.
"""

import fcntl
import importlib.util
import json
import os
import signal
import socket
import subprocess
import sys
import sysconfig
import time
import urllib.request

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))

# The reaper selects processes SYSTEM-WIDE, so two suites running at once have
# one run's main() killing the other run's fixtures -- an assertion then passes
# or fails for reasons that have nothing to do with the code under test. The
# path is fixed rather than tmp_path so that copies of this file (mutation-check
# runs the suite from a throwaway directory) contend on the same lock.
_LOCK_PATH = "/tmp/preview-reap-tests.lock"


def load_reaper():
    """Import preview-reap.py by path -- the hyphen makes it unimportable by name."""
    path = os.path.join(HERE, "preview-reap.py")
    spec = importlib.util.spec_from_file_location("preview_reap", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(autouse=True)
def _serialised():
    """Hold an exclusive lock for the whole test: see _LOCK_PATH."""
    with open(_LOCK_PATH, "w") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        yield


@pytest.fixture
def reaper(tmp_path):
    mod = load_reaper()
    mod.STATE = str(tmp_path / "state.json")
    # Where preview.sh writes its per-port request logs.
    mod.LOG_DIR = str(tmp_path)
    return mod


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def alive(proc):
    return proc.poll() is None


def spawn_static(tmp_path, log_age_seconds):
    """A detached `python3 -m http.server ... --directory`, as preview.sh spawns it."""
    port = free_port()
    log = tmp_path / f"preview-static-{port}.log"
    log.write_text("")
    with open(log, "a") as sink:
        proc = subprocess.Popen(
            [sys.executable, "-m", "http.server", str(port),
             "--bind", "127.0.0.1", "--directory", str(tmp_path)],
            stdout=sink, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    _wait_listening(port)
    _age(log, log_age_seconds)
    return proc, port, log


def spawn_origin_proxy(tmp_path, log_age_seconds):
    """A detached origin-proxy.py stand-in: same argv shape, same log name."""
    port = free_port()
    log = tmp_path / f"preview-origin-proxy-{port}.log"
    log.write_text("")
    script = tmp_path / "origin-proxy.py"
    script.write_text(
        "import sys, time\n"
        "sys.stderr.write('proxy up\\n')\n"
        "time.sleep(600)\n"
    )
    with open(log, "a") as sink:
        proc = subprocess.Popen(
            [sys.executable, str(script), "127.0.0.1", str(port), "9999"],
            stdout=sink, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    time.sleep(0.3)
    _age(log, log_age_seconds)
    return proc, port, log


def _wait_listening(port, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            return
        except OSError:
            time.sleep(0.05)
    raise AssertionError(f"server on {port} never came up")


def _age(log, seconds):
    """Backdate the request log: this is the reaper's 'last used' signal."""
    when = time.time() - seconds
    os.utime(log, (when, when))


def run_reaper(mod, times):
    for _ in range(times):
        mod.main()
        time.sleep(0.05)


def reap_and_wait(mod, proc, times, settle=2.0):
    run_reaper(mod, times)
    deadline = time.time() + settle
    while time.time() < deadline and alive(proc):
        time.sleep(0.05)


def cleanup(proc):
    if alive(proc):
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except OSError:
            pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


# ── the static preview server ────────────────────────────────────────────────

def test_static_server_with_a_recent_request_survives(reaper, tmp_path):
    """A preview someone is still loading must never be reaped."""
    proc, _, _ = spawn_static(tmp_path, log_age_seconds=0)
    try:
        reap_and_wait(reaper, proc, times=3, settle=1.0)
        assert alive(proc), "reaped a static server that served a request just now"
    finally:
        cleanup(proc)


def test_idle_static_server_is_reaped(reaper, tmp_path):
    """No request for over the threshold, and no CPU, twice running -> reaped."""
    proc, _, _ = spawn_static(tmp_path, log_age_seconds=45 * 60)
    try:
        reap_and_wait(reaper, proc, times=3)
        assert not alive(proc), "idle static server survived three reaper runs"
    finally:
        cleanup(proc)


def test_idle_static_server_survives_a_single_run(reaper, tmp_path):
    """One observation is never enough -- the two-strike rule must hold."""
    proc, _, _ = spawn_static(tmp_path, log_age_seconds=45 * 60)
    try:
        reap_and_wait(reaper, proc, times=1, settle=1.0)
        assert alive(proc), "killed on the first sighting; strike rule not applied"
    finally:
        cleanup(proc)


def test_recent_request_resets_the_strike_count(reaper, tmp_path):
    """A request between runs clears accumulated strikes."""
    proc, _, log = spawn_static(tmp_path, log_age_seconds=45 * 60)
    try:
        run_reaper(reaper, 2)
        _age(log, 0)          # someone loaded the page again
        reap_and_wait(reaper, proc, times=1, settle=1.0)
        assert alive(proc), "strikes were not reset by a fresh request"
    finally:
        cleanup(proc)


# ── the tailscale origin proxy ───────────────────────────────────────────────

def test_idle_origin_proxy_is_reaped(reaper, tmp_path):
    proc, _, _ = spawn_origin_proxy(tmp_path, log_age_seconds=45 * 60)
    try:
        reap_and_wait(reaper, proc, times=3)
        assert not alive(proc), "idle origin-proxy survived three reaper runs"
    finally:
        cleanup(proc)


def test_active_origin_proxy_survives(reaper, tmp_path):
    """A proxy relaying real traffic must survive, whatever its log mtime says.

    This used to stage "active" by calling os.utime on the proxy's log, which
    is an event production cannot produce: the real origin-proxy.py never
    writes to that file, so its mtime is frozen at spawn (see
    spawn_silent_origin_proxy). The staging here is one the real proxy does
    produce -- bytes spliced between a client and the upstream server, which
    burns CPU between reaper runs -- while the log is held stale throughout.
    """
    proc, port, upstream, log = spawn_splicing_origin_proxy(
        tmp_path, log_age_seconds=45 * 60)
    try:
        for _ in range(3):
            serve_requests(proc, port, tmp_path)
            _age(log, 45 * 60)     # the proxy never writes it; mtime never moves
            run_reaper(reaper, 1)
        time.sleep(1.0)
        assert alive(proc), "reaped an origin-proxy that was relaying requests"
    finally:
        cleanup(proc)
        cleanup(upstream)


# ── unrelated processes are not candidates ───────────────────────────────────

def test_unrelated_python_process_is_untouched(reaper):
    """A plain python sleeper matches no rule and must be left alone."""
    proc = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(600)"],
        start_new_session=True,
    )
    try:
        reap_and_wait(reaper, proc, times=3, settle=1.0)
        assert alive(proc), "reaped a process matching no rule"
    finally:
        cleanup(proc)


def test_tinymist_rule_is_still_present(reaper):
    """The rename must not drop the tinymist rule this script started as."""
    names = {r.name for r in reaper.RULES}
    assert "tinymist" in names, f"tinymist rule missing; rules are {names}"
    assert {"preview-static", "origin-proxy"} <= names, f"rules are {names}"


def test_nix_wires_the_renamed_reaper():
    """The systemd unit must point at preview-reap.py, with no tinymist-reap left."""
    with open(os.path.join(HERE, "..", "default.nix")) as fh:
        nix = fh.read()
    assert "files/preview-reap.py" in nix, "default.nix does not reference preview-reap.py"
    assert "tinymist-reap" not in nix, "a tinymist-reap reference survives in default.nix"


# ── staging helpers for the cases below ──────────────────────────────────────

def cpu_ticks(pid):
    """utime + stime of a live pid, the same counter the reaper samples."""
    with open(f"/proc/{pid}/stat") as fh:
        fields = fh.read().rsplit(")", 1)[1].split()
    return int(fields[11]) + int(fields[12])


def serve_requests(proc, port, tmp_path, min_ticks=2, timeout=20.0):
    """Drive real HTTP traffic at the server until its CPU counter has moved.

    A preview someone is actively using burns CPU between reaper runs; this is
    how a test stages that fact without touching the reaper.
    """
    payload = tmp_path / "payload.bin"
    if not payload.exists():
        payload.write_bytes(b"x" * (256 * 1024))
    start = cpu_ticks(proc.pid)
    deadline = time.time() + timeout
    while time.time() < deadline:
        for _ in range(20):
            with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/payload.bin", timeout=5) as resp:
                resp.read()
        if cpu_ticks(proc.pid) - start >= min_ticks:
            return
    raise AssertionError(
        f"server on {port} burned no measurable CPU while serving requests")


def _real_interpreter():
    """An interpreter that is a real ELF, not a nix exec-wrapper.

    comm is taken from the file execve() actually runs, so a wrapper that
    re-execs the interpreter resets comm to `python3.x` and the shim below
    would never look like tinymist.
    """
    candidate = os.path.join(
        sysconfig.get_config_var("BINDIR") or "", "python3")
    if os.path.exists(candidate):
        return os.path.realpath(candidate)
    return os.path.realpath(sys.executable)


def spawn_tinymist_shim(tmp_path, args):
    """A detached process whose /proc comm reads `tinymist`.

    Running python through a symlink named `tinymist` is what makes comm match;
    `args` decides whether this is a preview server or the plain LSP.
    """
    shim = tmp_path / "tinymist"
    if not shim.exists():
        shim.symlink_to(_real_interpreter())
    proc = subprocess.Popen(
        [str(shim), "-c", "import time; time.sleep(600)"] + args,
        start_new_session=True,
    )
    deadline = time.time() + 5.0
    while time.time() < deadline:
        with open(f"/proc/{proc.pid}/comm") as fh:
            if fh.read().strip() == "tinymist":
                return proc
        time.sleep(0.05)
    cleanup(proc)
    raise AssertionError("the shim never execed into a process named tinymist")


# ── what the idle rule must NOT treat as idle ────────────────────────────────

def test_busy_static_server_survives_a_backdated_log(reaper, tmp_path):
    """Serving real requests must save a server even when its log looks stale.

    The log mtime alone is not the rule: a server burning CPU between runs is
    in use, whatever its log says.
    """
    proc, port, log = spawn_static(tmp_path, log_age_seconds=45 * 60)
    try:
        for _ in range(3):
            serve_requests(proc, port, tmp_path)
            _age(log, 45 * 60)     # pretend the log never recorded the traffic
            run_reaper(reaper, 1)
        time.sleep(1.0)
        assert alive(proc), "reaped a static server that was serving requests"
    finally:
        cleanup(proc)


def test_static_server_with_no_log_at_all_survives(reaper, tmp_path):
    """A log that cannot be found means 'no idea', never 'idle'."""
    proc, _, log = spawn_static(tmp_path, log_age_seconds=45 * 60)
    try:
        os.unlink(log)
        reap_and_wait(reaper, proc, times=3, settle=1.0)
        assert alive(proc), "reaped a static server whose request log was missing"
    finally:
        cleanup(proc)


def test_strikes_rebuild_from_zero_after_a_request(reaper, tmp_path):
    """A reset must clear the count, not merely pause it.

    Two stale runs, then a fresh request, then one stale run again: correct code
    is back at one strike and the server lives.
    """
    proc, _, log = spawn_static(tmp_path, log_age_seconds=45 * 60)
    try:
        run_reaper(reaper, 2)
        _age(log, 0)              # someone loaded the page again
        run_reaper(reaper, 1)
        _age(log, 45 * 60)        # and then went away again
        reap_and_wait(reaper, proc, times=1, settle=1.0)
        assert alive(proc), "strikes were held across a request instead of reset"
    finally:
        cleanup(proc)


# ── which tinymist processes the rule may select ─────────────────────────────

def test_tinymist_without_preview_in_argv_survives(reaper, tmp_path):
    """comm `tinymist` with no `preview` argument is the plain LSP, not a server."""
    proc = spawn_tinymist_shim(tmp_path, [])
    try:
        reap_and_wait(reaper, proc, times=3, settle=1.0)
        assert alive(proc), "reaped a plain tinymist LSP that serves no preview"
    finally:
        cleanup(proc)


def test_tinymist_preview_not_parented_by_nvim_is_reaped_at_once(reaper, tmp_path):
    """Parent is not nvim -> the editor is gone; that is a kill on sight."""
    proc = spawn_tinymist_shim(tmp_path, ["preview"])
    try:
        assert alive(proc), "the shim died on its own; the kill below proves nothing"
        reap_and_wait(reaper, proc, times=1)
        assert not alive(proc), "orphaned tinymist preview survived the first run"
    finally:
        cleanup(proc)


# ── a tinymist preview the editor is still holding ───────────────────────────

# argv is `-c <code> preview <port> <marker>`, so sys.argv reads
# ['-c', 'preview', port, marker]. The accepted connections are kept, because
# the point of the fixture is a socket that stays ESTABLISHED; the marker file
# is how the test knows one has been accepted rather than left in the backlog,
# where it would carry no inode the reaper could attribute to this process.
_TINYMIST_CHILD = (
    "import socket, sys\n"
    "s = socket.socket()\n"
    "s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
    "s.bind(('127.0.0.1', int(sys.argv[2])))\n"
    "s.listen(5)\n"
    "held = []\n"
    "while True:\n"
    "    conn, _ = s.accept()\n"
    "    held.append(conn)\n"
    "    open(sys.argv[3], 'a').write('x')\n"
)

_NVIM_PARENT = (
    "import subprocess, sys, time\n"
    "shim, port, marker, codefile, pidfile = sys.argv[1:6]\n"
    "p = subprocess.Popen(\n"
    "    [shim, '-c', open(codefile).read(), 'preview', port, marker])\n"
    "open(pidfile, 'w').write(str(p.pid))\n"
    "time.sleep(600)\n"
)


def pid_running(pid):
    """True while pid is a live process -- a reaped child left unwaited is a zombie."""
    try:
        with open(f"/proc/{pid}/stat") as fh:
            fields = fh.read().rsplit(")", 1)[1].split()
    except OSError:
        return False
    return fields[0] != "Z"


def _await_comm(pid, want, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(f"/proc/{pid}/comm") as fh:
                if fh.read().strip() == want:
                    return
        except OSError:
            pass
        time.sleep(0.05)
    raise AssertionError(f"pid {pid} never became a process named {want}")


def spawn_nvim_parented_tinymist(tmp_path, port, child_code=None,
                                 attach_client=True):
    """A tinymist preview whose PARENT's comm reads `nvim`, as a live editor's does.

    The orphan rule is checked before the idle rule and kills on sight, so a
    shim parented by pytest never reaches the idle path at all. Staging a live
    editor takes a real parent process named `nvim` that spawns the shim and
    stays alive. The child binds `port`, accepts one connection and then
    blocks -- holding an ESTABLISHED socket while burning no CPU, which is
    exactly the state a preview someone is watching but not editing is in.

    `child_code` swaps that child for another shape (a preview burning CPU with
    nothing connected, say), and `attach_client=False` leaves it with no client
    at all -- an abandoned preview the editor has not yet let go of.
    """
    nvim = tmp_path / "nvim"
    nvim.symlink_to(_real_interpreter())
    shim = tmp_path / "tinymist"
    if not shim.exists():
        shim.symlink_to(_real_interpreter())
    codefile = tmp_path / "child.py"
    codefile.write_text(child_code or _TINYMIST_CHILD)
    pidfile = tmp_path / "child.pid"
    marker = tmp_path / "accepted"

    parent = subprocess.Popen(
        [str(nvim), "-c", _NVIM_PARENT, str(shim), str(port), str(marker),
         str(codefile), str(pidfile)],
        start_new_session=True,
    )
    _await_comm(parent.pid, "nvim")

    deadline = time.time() + 5.0
    while time.time() < deadline:
        if pidfile.exists() and pidfile.read_text().strip():
            break
        time.sleep(0.05)
    child_pid = int(pidfile.read_text().strip())
    _await_comm(child_pid, "tinymist")

    if not attach_client:
        return parent, child_pid, None

    # One connection only, and it is never closed -- a probe that connected and
    # hung up would leave the preview holding a CLOSE_WAIT socket, not a client.
    deadline = time.time() + 5.0
    while True:
        try:
            client = socket.create_connection(("127.0.0.1", port), 0.2)
            break
        except OSError:
            if time.time() > deadline:
                raise AssertionError(f"preview on {port} never came up")
            time.sleep(0.05)
    while time.time() < deadline + 5.0:
        if marker.exists() and marker.read_text():
            return parent, child_pid, client
        time.sleep(0.05)
    client.close()
    raise AssertionError("the preview never accepted the client connection")


def _kill_all(parent, child_pid):
    """Tear down an nvim-parented preview: the child first, then the parent."""
    for pid in (child_pid, parent.pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    cleanup(parent)


def test_tinymist_preview_with_a_live_client_survives(reaper, tmp_path):
    """A watched preview burns no CPU, and the open client is the only thing saying so.

    No CPU delta alone is true of every idle-looking preview; what separates
    "still on someone's screen" from "abandoned" is the ESTABLISHED socket.
    A reaper that stopped consulting it would kill this one on the second
    strike.
    """
    port = free_port()
    # `client` is the browser end, held open for the whole test
    parent, child_pid, client = spawn_nvim_parented_tinymist(tmp_path, port)
    try:
        assert pid_running(child_pid), "the preview died before the reaper ran"

        run_reaper(reaper, 3)
        time.sleep(1.0)
        assert pid_running(child_pid), (
            "reaped a tinymist preview that still had a connected client")
    finally:
        client.close()
        for pid in (child_pid, parent.pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        cleanup(parent)


# ── the log must belong to the process, not merely share its port number ─────

def test_static_server_not_writing_the_log_survives(reaper, tmp_path):
    """A stale log must not adopt an unrelated server that reuses its port.

    Nothing deletes /tmp/preview-static-<port>.log -- `preview --stop` pkills
    the process and leaves the file -- so a log outlives the server it belonged
    to by days. Run your own `python3 -m http.server <port> --directory .` in a
    terminal on that port and it matches the rule on shape alone, while its
    output goes to the tty and never touches the log. The log is stale forever,
    so the process reads as idle on every run and dies while in use. Ownership
    has to come from the process itself: the server preview.sh spawned holds
    that log open as its stdout, and this one does not.
    """
    port = free_port()
    stale = tmp_path / f"preview-static-{port}.log"
    stale.write_text("a log left behind by a server that no longer exists\n")
    _age(stale, 3 * 24 * 60 * 60)

    proc = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(port),
         "--bind", "127.0.0.1", "--directory", str(tmp_path)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        _wait_listening(port)
        reap_and_wait(reaper, proc, times=3, settle=1.0)
        assert alive(proc), "reaped a server that never wrote the log claiming its port"
    finally:
        cleanup(proc)


# ── the origin proxy writes nothing, so its log is not a "last used" stamp ────

def spawn_silent_origin_proxy(tmp_path, log_age_seconds):
    """An origin proxy that behaves like the real one: it never logs.

    ~/.claude/skills/preview/scripts/origin-proxy.py is a bare asyncio socket
    splice with no print, no stderr write and no logger. preview.sh creates
    /tmp/preview-origin-proxy-<port>.log purely as a redirection target, so the
    file is empty and its mtime is frozen at spawn for the life of the process,
    however heavily the proxy is used. The stand-in in spawn_origin_proxy above
    logs a startup line, which is why it reads as "recently active" in a way
    production never can.
    """
    port = free_port()
    log = tmp_path / f"preview-origin-proxy-{port}.log"
    log.write_text("")
    script = tmp_path / "origin-proxy.py"
    script.write_text(
        "import socket, sys, time\n"
        "s = socket.socket()\n"
        "s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
        "s.bind(('127.0.0.1', int(sys.argv[2])))\n"
        "s.listen(8)\n"
        "held = []\n"
        "while True:\n"
        "    held.append(s.accept()[0])\n"
    )
    with open(log, "a") as sink:
        proc = subprocess.Popen(
            [sys.executable, str(script), "127.0.0.1", str(port), "9999"],
            stdout=sink, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    _wait_listening(port)
    _age(log, log_age_seconds)
    return proc, port, log


def test_origin_proxy_with_a_live_client_survives(reaper, tmp_path):
    """A tailnet preview held open must not die because its log never moves.

    The proxy's log mtime is frozen at spawn, so every proxy is permanently
    "log-idle" half an hour after it starts. The only signal that distinguishes
    a proxy someone is reading through from an abandoned one is the ESTABLISHED
    socket the live client holds -- the same signal the tinymist rule already
    uses. Without it a phone left on a rendered preview, quiet across two
    sampling windows, is SIGTERMed in use.
    """
    proc, port, _ = spawn_silent_origin_proxy(tmp_path, log_age_seconds=45 * 60)
    client = socket.create_connection(("127.0.0.1", port), 2.0)
    try:
        assert alive(proc), "the proxy died on its own; the rest proves nothing"
        reap_and_wait(reaper, proc, times=3, settle=1.0)
        assert alive(proc), "reaped an origin proxy with a live client attached"
    finally:
        client.close()
        cleanup(proc)


def test_abandoned_origin_proxy_holding_only_a_listener_is_reaped(reaper, tmp_path):
    """The listening socket must not read as a client, or nothing ever reaps.

    An abandoned proxy is not socket-less: it sits in accept() on a LISTENING
    socket for as long as it lives, which is the state `preview --stop` never
    cleans up. Only ESTABLISHED counts as a client, so this one must still die.
    """
    proc, _, _ = spawn_silent_origin_proxy(tmp_path, log_age_seconds=45 * 60)
    try:
        assert alive(proc), "the proxy died on its own; the kill below proves nothing"
        reap_and_wait(reaper, proc, times=3)
        assert not alive(proc), (
            "an abandoned origin proxy survived; a LISTENING socket was read as a client")
    finally:
        cleanup(proc)


# A blocking-thread miniature of the real origin-proxy.py: accept a connection,
# open one upstream connection to the target port, and splice bytes both ways
# until either side hangs up. One request per connection, as production does.
# It never writes to stdout or stderr, so its log's mtime stays frozen.
_SPLICING_PROXY = (
    "import socket, sys, threading\n"
    "host, port, target = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])\n"
    "def pipe(a, b):\n"
    "    try:\n"
    "        while True:\n"
    "            chunk = a.recv(65536)\n"
    "            if not chunk:\n"
    "                break\n"
    "            b.sendall(chunk)\n"
    "    except OSError:\n"
    "        pass\n"
    "    try:\n"
    "        b.shutdown(socket.SHUT_WR)\n"
    "    except OSError:\n"
    "        pass\n"
    "def handle(c):\n"
    "    try:\n"
    "        u = socket.create_connection(('127.0.0.1', target))\n"
    "    except OSError:\n"
    "        c.close()\n"
    "        return\n"
    "    threading.Thread(target=pipe, args=(c, u), daemon=True).start()\n"
    "    pipe(u, c)\n"
    "    c.close()\n"
    "    u.close()\n"
    "s = socket.socket()\n"
    "s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
    "s.bind((host, port))\n"
    "s.listen(8)\n"
    "while True:\n"
    "    threading.Thread(target=handle, args=(s.accept()[0],),"
    " daemon=True).start()\n"
)


def spawn_splicing_origin_proxy(tmp_path, log_age_seconds):
    """A proxy that really relays, in front of a real server, as preview.sh does.

    preview.sh puts the origin proxy in front of the static preview server, so
    traffic a phone sends arrives through the proxy and is spliced upstream.
    The upstream here writes to /dev/null, so it owns no request log and the
    static rule can never call it idle -- it is scaffolding, not the subject.
    """
    upstream_port = free_port()
    upstream = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(upstream_port),
         "--bind", "127.0.0.1", "--directory", str(tmp_path)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    _wait_listening(upstream_port)

    port = free_port()
    log = tmp_path / f"preview-origin-proxy-{port}.log"
    log.write_text("")
    script = tmp_path / "origin-proxy.py"
    script.write_text(_SPLICING_PROXY)
    with open(log, "a") as sink:
        proc = subprocess.Popen(
            [sys.executable, str(script), "127.0.0.1", str(port),
             str(upstream_port)],
            stdout=sink, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    _wait_listening(port)
    _age(log, log_age_seconds)
    return proc, port, upstream, log


# ── a tinymist preview nobody is watching ────────────────────────────────────

# Same argv shape as _TINYMIST_CHILD, but this one burns CPU instead of
# blocking: a preview recompiling on every keystroke while the browser tab is
# gone. No client, plenty of CPU -- the case the CPU conjunct exists for.
_TINYMIST_BUSY_CHILD = (
    "import sys\n"
    "n = 0\n"
    "while True:\n"
    "    n = (n + 1) % 1000003\n"
)


def test_idle_tinymist_preview_is_reaped_on_the_second_strike(reaper, tmp_path):
    """A preview the editor still holds, with no client and no CPU, is abandoned.

    The orphan branch cannot reach this one -- its parent really is nvim -- so
    the idle rule is what decides, and it must take two strikes to do it.
    """
    port = free_port()
    parent, child_pid, _ = spawn_nvim_parented_tinymist(
        tmp_path, port, attach_client=False)
    try:
        assert pid_running(child_pid), "the preview died before the reaper ran"

        run_reaper(reaper, 2)
        time.sleep(1.0)
        assert pid_running(child_pid), (
            "killed before the second strike; the strike rule was not applied")

        run_reaper(reaper, 1)
        deadline = time.time() + 2.0
        while time.time() < deadline and pid_running(child_pid):
            time.sleep(0.05)
        assert not pid_running(child_pid), (
            "an idle tinymist preview with no client survived the idle path")
    finally:
        _kill_all(parent, child_pid)


def test_busy_tinymist_preview_with_no_client_survives(reaper, tmp_path):
    """CPU alone must save a preview whose client socket is already gone.

    Closing a tab does not always leave the socket behind, and a preview that
    is recompiling is in use whether or not anything is connected to it. A
    reaper that judged tinymist on the client alone would kill this one on the
    second strike.
    """
    port = free_port()
    parent, child_pid, _ = spawn_nvim_parented_tinymist(
        tmp_path, port, child_code=_TINYMIST_BUSY_CHILD, attach_client=False)
    try:
        before = cpu_ticks(child_pid)
        run_reaper(reaper, 3)
        time.sleep(1.0)
        assert pid_running(child_pid), (
            "reaped a tinymist preview that was burning CPU between runs")
        assert cpu_ticks(child_pid) - before >= 2, (
            "the fixture burned no measurable CPU; it stages nothing")
    finally:
        _kill_all(parent, child_pid)


def test_tinymist_preview_with_an_unreadable_parent_survives(
        reaper, tmp_path, monkeypatch):
    """An unreadable /proc/<ppid>/comm means "no idea", never "the editor is gone".

    comm_of returns None when the parent cannot be read -- a race with the
    editor's own exit, or a hidepid mount. Real /proc cannot be made to do that
    on demand, so comm_of is redirected here; the real _tinymist_orphan, the
    real RULES table and the real main() still decide the outcome. Reading
    "not nvim" out of that None would SIGTERM a preview someone is watching.
    """
    port = free_port()
    # `client` is the browser end, held open for the whole test
    parent, child_pid, client = spawn_nvim_parented_tinymist(tmp_path, port)
    monkeypatch.setattr(reaper, "comm_of", lambda pid: None)
    try:
        assert pid_running(child_pid), "the preview died before the reaper ran"
        run_reaper(reaper, 3)
        time.sleep(1.0)
        assert pid_running(child_pid), (
            "reaped a live preview whose parent's comm could not be read")
    finally:
        client.close()
        _kill_all(parent, child_pid)


# ── the strike state must not survive a recycled pid ─────────────────────────

def starttime_of(pid):
    """Field 22 of /proc/<pid>/stat, the value that makes a pid entry unique."""
    with open(f"/proc/{pid}/stat") as fh:
        return fh.read().rsplit(")", 1)[1].split()[19]


def test_strike_state_is_keyed_by_pid_and_starttime(reaper, tmp_path):
    """Strikes are pinned to the process, not merely to its pid number.

    Pids are recycled within minutes on a busy machine. A count filed under the
    bare pid is inherited by whatever lands on that number next, which arrives
    already carrying somebody else's strikes and is killed early. The state the
    reaper writes is where that guard is visible.
    """
    proc, _, _ = spawn_static(tmp_path, log_age_seconds=45 * 60)
    try:
        start = starttime_of(proc.pid)
        run_reaper(reaper, 1)
        with open(reaper.STATE) as fh:
            state = json.load(fh)
        assert f"{proc.pid}:{start}" in state, (
            f"no entry keyed by pid and starttime; state keys are {list(state)}")
        assert str(proc.pid) not in state, (
            "an entry is keyed by the bare pid, so a recycled pid inherits it")
    finally:
        cleanup(proc)


def test_origin_proxy_not_spawned_by_preview_sh_survives(reaper, tmp_path):
    """Matching argv is not provenance: the reaper must own what it kills.

    Rule `origin-proxy` selects on comm plus an argv element ending in
    origin-proxy.py. While its idle test was log-based that was harmless --
    owned_log() returned None for anything preview.sh had not redirected, so
    the process was never idle and never killable. Taking idle from the
    ESTABLISHED-socket signal removed that gate as a side effect, and selection
    is now argv alone: a copy run by hand or from a second checkout, or a proxy
    sitting at a pdb breakpoint, holds no socket and burns no CPU and is
    reaped. Provenance has to be part of the match, not a side effect of the
    idle rule.
    """
    script = tmp_path / "origin-proxy.py"
    script.write_text("import time\ntime.sleep(600)\n")
    proc = subprocess.Popen(
        [sys.executable, str(script), "127.0.0.1", str(free_port()), "9999"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        assert alive(proc), "the stand-in died on its own; the rest proves nothing"
        reap_and_wait(reaper, proc, times=3, settle=1.0)
        assert alive(proc), "reaped an origin-proxy.py that preview.sh never spawned"
    finally:
        cleanup(proc)
