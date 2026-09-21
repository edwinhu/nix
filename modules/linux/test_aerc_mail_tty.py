"""Exercise the Nix-defined `aerc-mail-tty` launcher without building a profile.

Run: python3 -m pytest -q modules/linux/test_aerc_mail_tty.py
The Nix packaging primitives are stubs; the evaluated shell and mail helpers are
real. The launcher is what aerc's `o` runs via :exec-tty, on aerc's OWN
terminal: it must serve the message it was handed and run terminal-browser on
the served URL, with --no-merge so the browser takes that tty instead of
adopting a neighbour, and with no fallback to a stale URL. When the browser
quits it must reap the preview server it started, rather than leaving it
resident until the next open.
"""

import ctypes
import functools
import json
import os
import re
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.request import urlopen

import pytest

ROOT = Path(__file__).resolve().parents[2]
HELPERS = ROOT / "hosts/linux/omarchy/files"

MESSAGE = b"""MIME-Version: 1.0
Subject: O-TERM FIXTURE subject
From: Fixture <fixture@example.invalid>
To: Fixture <fixture@example.invalid>
Content-Type: multipart/alternative; boundary="oterm"

--oterm
Content-Type: text/plain; charset=utf-8

O-TERM FIXTURE
--oterm
Content-Type: text/html; charset=utf-8

<html><body><p>O-TERM FIXTURE</p></body></html>
--oterm--
"""

# Fetches the page and copies the url record WHILE THE PREVIEW IS STILL LIVE.
# The launcher reaps on the way out, so after the run the server is gone and the
# record with it; both are only observable from in here -- which is also where
# the real browser does its fetching. $BROWSER_EXIT lets a test make the browser
# fail the way a crash or a signal would.
FAKE_BROWSER = """#!/usr/bin/env bash
printf '%s\\n' "$@" > "$ARGV_OUT"
env > "$ENV_OUT"
cat "$XDG_RUNTIME_DIR/aerc-mail-browser-url" > "$RECORD_OUT" 2>/dev/null || true
python3 -c 'import sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=5) as r:
    open(sys.argv[2], "wb").write(r.read())
    open(sys.argv[3], "w").write(str(r.status))' "$2" "$BODY_OUT" "$STATUS_OUT" || true
exit "${BROWSER_EXIT:-0}"
"""

HERDR_ENV = {
    "HERDR_PANE_ID": "7",
    "HERDR_SOCKET_PATH": "/run/user/1000/herdr.sock",
    "HERDR_TAB_ID": "3",
    "HERDR_ENV": "1",
}


# Sibling scripts the launcher may call (the serve step is one) evaluate to this
# stand-in path, which the test replaces with a real executable copy.
SIBLING = "/@nix-script@/"


def capture(name):
    """Evaluate the module with stubbed packaging, capturing one script's text."""
    expression = r"""
      import MODULE {
        lib.makeBinPath = _: "/usr/bin:/bin";
        writeText = name: _: "/nix/store/00000000000000000000000000000000-" + name;
        writeShellScript = name: text:
          if name == "WANTED" then
            "TERM_BEGIN" + builtins.toJSON text + "TERM_END"
          # A script only reachable THROUGH another one -- the reaper, which
          # only the serve step names -- is never forced if every other stub
          # discards its text, and the capture comes back empty. So a stub
          # whose text already carries the marker yields that text instead of a
          # path, floating the wanted script up to where symlinkJoin's
          # postBuild puts it in the output.
          else if builtins.length (builtins.split "TERM_BEGIN" text) > 1 then text
          else "SIBLING" + name;
        symlinkJoin = attrs: attrs.postBuild;
        python3 = null; coreutils = null; aerc = null;
        mailServe = SERVER;
        mailInlineImages = INLINE;
      }
    """
    expression = expression.replace("WANTED", name).replace("SIBLING", SIBLING)
    expression = expression.replace(
        "MODULE", str(ROOT / "modules/linux/aerc-html-terminal-browser.nix")
    )
    expression = expression.replace("SERVER", json.dumps(str(HELPERS / "mail-serve.py")))
    expression = expression.replace(
        "INLINE", json.dumps(str(HELPERS / "mail-inline-images.py"))
    )
    result = subprocess.run(
        ["nix", "eval", "--impure", "--raw", "--expr", expression],
        check=True,
        capture_output=True,
        text=True,
    )
    out = result.stdout
    if "TERM_BEGIN" not in out:
        return ""
    return json.loads(out.split("TERM_BEGIN", 1)[1].split("TERM_END", 1)[0])


@pytest.fixture(scope="module")
def script():
    # Adopt only our detached descendants, so the test can reap the server it
    # started rather than depending on the host's PID 1.
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
    text = capture("aerc-mail-tty")
    print(f"\ncaptured aerc-mail-tty script: {len(text)} bytes", flush=True)
    return text


@pytest.fixture
def sandbox():
    with tempfile.TemporaryDirectory(prefix="aerc-tty-test-") as name:
        root = Path(name)
        home = root / "home"
        runtime = root / "runtime"
        docs = root / "docs"
        for directory in (home, runtime, docs):
            directory.mkdir()
        browser = home / ".local/share/terminal-browser/app/bin/terminal-browser"
        browser.parent.mkdir(parents=True)
        browser.write_text(FAKE_BROWSER)
        browser.chmod(0o755)
        state = {
            "root": root,
            "home": home,
            "runtime": runtime,
            "argv": root / "argv.txt",
            "envfile": root / "env.txt",
            "urlfile": runtime / "aerc-mail-browser-url",
            "record": root / "record.txt",
            "body": root / "body.html",
            "status": root / "status.txt",
            "message": root / "message.eml",
        }
        state["message"].write_bytes(MESSAGE)
        state["env"] = dict(
            os.environ,
            HOME=str(home),
            TMPDIR=str(docs),
            XDG_RUNTIME_DIR=str(runtime),
            ARGV_OUT=str(state["argv"]),
            ENV_OUT=str(state["envfile"]),
            RECORD_OUT=str(state["record"]),
            BODY_OUT=str(state["body"]),
            STATUS_OUT=str(state["status"]),
            **HERDR_ENV,
        )
        try:
            yield state
        finally:
            _reap(state["urlfile"])


SIBLINGS = ("aerc-mail-serve", "aerc-mail-reap")


@functools.cache
def _sibling_source(name):
    return capture(name)


def install(sandbox, name):
    """Write a real executable copy of a sibling script into the sandbox."""
    path = sandbox["root"] / name
    if not path.exists():
        text = _sibling_source(name)
        assert text, f"module defines no {name} script"
        # A sibling may reference siblings of its own -- serve calls the reaper.
        path.write_text("#!/usr/bin/env bash\n" + runnable(text, sandbox))
        path.chmod(0o755)
    return path


def runnable(script, sandbox):
    """Give a script real sibling steps where the module referenced stubs."""
    for name in SIBLINGS:
        marker = SIBLING + name
        if marker in script:
            script = script.replace(marker, str(install(sandbox, name)))
    return script


def _reap(urlfile):
    """Teardown net for tests that leave a record -- serve run on its own.

    After a launcher run the record is gone, because the launcher reaped it;
    read_text then raises and this returns immediately.
    """
    try:
        lines = urlfile.read_text().splitlines()
    except OSError:
        return
    if len(lines) < 3 or not re.fullmatch(r"[1-9][0-9]*", lines[2]):
        return
    pid = int(lines[2])
    try:
        waited, _ = os.waitpid(pid, os.WNOHANG)
        if waited == 0:
            os.kill(pid, signal.SIGTERM)
            os.waitpid(pid, 0)
    except (ChildProcessError, ProcessLookupError, OSError):
        pass


def test_module_defines_aerc_mail_term(script):
    assert script, "module defines no aerc-mail-tty script"
    subprocess.run(["bash", "-n"], input=script, text=True, check=True)
    print("bash -n accepted aerc-mail-tty", flush=True)


def test_launcher_serves_and_execs_terminal_browser(script, sandbox):
    assert script, "module defines no aerc-mail-tty script"
    result = subprocess.run(
        ["bash", "-c", runnable(script, sandbox), "aerc-mail-tty",
         str(sandbox["message"])],
        env=sandbox["env"],
        capture_output=True,
        timeout=60,
        check=False,
    )
    print(result.stdout.decode(errors="replace"), flush=True)
    print(result.stderr.decode(errors="replace"), flush=True)
    assert result.returncode == 0, result.stderr.decode(errors="replace")

    assert sandbox["argv"].exists(), "terminal-browser was never executed"
    argv = sandbox["argv"].read_text().splitlines()
    print(f"ARGV: {argv}", flush=True)
    assert "open" in argv, argv
    urls = [a for a in argv if re.fullmatch(r"http://127\.0\.0\.1:\d+/index\.html", a)]
    assert urls, argv
    assert "--app-mode" in argv, argv
    preload = [
        a
        for a in argv
        if a.startswith("--preload=") and a.endswith("aerc-pager-keys.js")
    ]
    assert preload, argv
    # --no-merge is what makes the browser take the tty aerc handed over
    # instead of adopting an instance already registered in the tab.
    assert "--no-merge" in argv, argv

    # The HERDR environment is KEPT on purpose: the engine streams frames into
    # the pane over HERDR_SOCKET_PATH/HERDR_PANE_ID, and --no-merge already
    # stops the pane hunt. Stripping it would drop the browser onto the slow
    # inline-kitty path.
    env_seen = dict(
        line.split("=", 1)
        for line in sandbox["envfile"].read_text().splitlines()
        if "=" in line
    )
    for name, value in HERDR_ENV.items():
        assert env_seen.get(name) == value, (name, env_seen.get(name))
    assert env_seen.get("TERMINAL_BROWSER_NO_MERGE") == "1", env_seen.get(
        "TERMINAL_BROWSER_NO_MERGE")

    # The browser fetched the page itself, while the preview was still live.
    body = sandbox["body"].read_bytes()
    print(f"HTTP {sandbox['status'].read_text()} from {urls[0]}", flush=True)
    assert b"O-TERM FIXTURE" in body, body[:400]

    lines = sandbox["record"].read_text().splitlines()
    assert len(lines) == 3, lines
    print(f"record while the browser ran: {lines}", flush=True)


KEPT_VARS = ("HERDR_PANE_ID", "HERDR_SOCKET_PATH", "HERDR_TAB_ID", "HERDR_ENV")


def test_launcher_keeps_the_herdr_environment(script):
    """:exec-tty hands over the terminal, so there is no pane to hunt for.

    The browser streams frames into the pane over HERDR_SOCKET_PATH/
    HERDR_PANE_ID; --no-merge, not an `env -u` strip, is what stops it adopting
    a neighbour. A strip here would silently downgrade it to inline kitty.
    """
    assert script, "module defines no aerc-mail-tty script"
    stripped = [
        name
        for name in KEPT_VARS
        if re.search(rf"-u\s+{name}\b", script)
        or re.search(rf"\bunset\b[^\n]*\b{name}\b", script)
    ]
    assert not stripped, f"launcher removes variables it must keep: {stripped}"
    assert "--no-merge" in script, "launcher never passes --no-merge"


SEEN_MESSAGE = MESSAGE.replace(b"O-TERM FIXTURE", b"SEEN-RENAME FIXTURE")


def test_launcher_recovers_seen_renamed_maildir_file(script, sandbox):
    """Opening an unread message renames the file before the launcher runs.

    Marking a message Seen appends the `S` flag to the maildir info part, so
    aerc's cached {{.Filename}} names a path that no longer exists. Only the
    flags after `:2,` change, so the launcher must recover by globbing the base.
    """
    assert script, "module defines no aerc-mail-tty script"
    maildir = sandbox["root"] / "maildir-cur"
    maildir.mkdir()
    base = maildir / "1700000000.1_1.host,U=42"
    (maildir / "1700000000.1_1.host,U=42:2,S").write_bytes(SEEN_MESSAGE)
    stale = f"{base}:2,"
    assert not Path(stale).exists(), stale

    result = subprocess.run(
        ["bash", "-c", runnable(script, sandbox), "aerc-mail-tty",
         stale],
        env=sandbox["env"],
        capture_output=True,
        timeout=60,
        check=False,
    )
    print(result.stdout.decode(errors="replace"), flush=True)
    print(result.stderr.decode(errors="replace"), flush=True)
    assert result.returncode == 0, result.stdout.decode(errors="replace")

    assert sandbox["argv"].exists(), "terminal-browser was never executed"
    argv = sandbox["argv"].read_text().splitlines()
    print(f"ARGV: {argv}", flush=True)
    assert "open" in argv, argv
    urls = [a for a in argv if re.fullmatch(r"http://127\.0\.0\.1:\d+/index\.html", a)]
    assert urls, argv

    body = sandbox["body"].read_bytes()
    print(f"HTTP {sandbox['status'].read_text()} from {urls[0]}", flush=True)
    assert b"SEEN-RENAME FIXTURE" in body, body[:400]


def test_launcher_refuses_when_no_flag_variant_exists(script, sandbox):
    """The glob fallback must not rescue a message that is genuinely gone."""
    assert script, "module defines no aerc-mail-tty script"
    maildir = sandbox["root"] / "maildir-empty"
    maildir.mkdir()
    result = subprocess.run(
        ["bash", "-c", runnable(script, sandbox), "aerc-mail-tty",
         str(maildir / "1700000000.9_9.host,U=99:2,")],
        env=sandbox["env"],
        capture_output=True,
        timeout=60,
        check=False,
    )
    print(f"exit={result.returncode}", flush=True)
    output = result.stdout.decode(errors="replace") + result.stderr.decode(errors="replace")
    print(output, flush=True)
    assert result.returncode != 0, "launcher accepted a message file that is not there"
    assert "no readable message file" in output, output
    assert not sandbox["argv"].exists(), "browser ran without a message"


def test_launcher_refuses_without_message(script, sandbox):
    assert script, "module defines no aerc-mail-tty script"
    missing = sandbox["root"] / "no-such-message.eml"
    result = subprocess.run(
        ["bash", "-c", runnable(script, sandbox), "aerc-mail-tty",
         str(missing)],
        env=sandbox["env"],
        capture_output=True,
        timeout=60,
        check=False,
    )
    print(f"exit={result.returncode}", flush=True)
    print(result.stderr.decode(errors="replace"), flush=True)
    assert result.returncode != 0, "launcher accepted a message file that is not there"
    assert not sandbox["argv"].exists(), "browser ran without a message"


STALE_URL = "http://127.0.0.1:65000/index.html"


def test_launcher_never_opens_a_stale_url(script, sandbox):
    """An unreadable message must be a visible error, not the previous mail.

    An earlier version fell back to whatever URL the shared file held, so `o`
    on a message aerc had already renamed opened the last thing served -- up to
    and including a test fixture. The launcher must remove that record before
    serving and refuse when it has nothing to serve.
    """
    assert script, "module defines no aerc-mail-tty script"
    sandbox["urlfile"].write_text(f"{STALE_URL}\n/nonexistent-dir\n1\n")

    result = subprocess.run(
        ["bash", "-c", runnable(script, sandbox), "aerc-mail-tty",
         str(sandbox["root"] / "gone.eml")],
        env=sandbox["env"],
        capture_output=True,
        timeout=60,
        check=False,
    )
    output = result.stdout.decode(errors="replace") + result.stderr.decode(
        errors="replace")
    print(f"exit={result.returncode}", flush=True)
    print(output, flush=True)
    assert result.returncode != 0, "launcher accepted an unreadable message"
    assert "no readable message file" in output, output
    assert not sandbox["argv"].exists(), "browser ran on the stale URL"


def test_launcher_never_serves_a_stale_url(script, sandbox):
    """A previous preview's URL is never what the browser is handed."""
    assert script, "module defines no aerc-mail-tty script"
    sandbox["urlfile"].write_text(f"{STALE_URL}\n/nonexistent-dir\n1\n")

    result = subprocess.run(
        ["bash", "-c", runnable(script, sandbox), "aerc-mail-tty",
         str(sandbox["message"])],
        env=sandbox["env"],
        capture_output=True,
        timeout=60,
        check=False,
    )
    print(result.stdout.decode(errors="replace"), flush=True)
    print(result.stderr.decode(errors="replace"), flush=True)
    assert result.returncode == 0, result.stderr.decode(errors="replace")

    argv = sandbox["argv"].read_text().splitlines()
    print(f"ARGV: {argv}", flush=True)
    assert STALE_URL not in argv, argv
    urls = [a for a in argv if re.fullmatch(r"http://127\.0\.0\.1:\d+/index\.html", a)]
    assert urls and urls[0] != STALE_URL, argv


def test_launcher_keeps_the_url_record_for_the_reaper(script):
    """The launcher must not delete the url file before serving.

    That file is the only record of the previous preview -- url, directory and
    pid on three lines -- and the serve step reads it to kill that server and
    remove its directory. A launcher that clears it first leaks a python server
    holding a rendered copy of a mail on every single open.
    """
    assert script, "module defines no aerc-mail-tty script"
    offenders = [
        line.strip()
        for line in script.splitlines()
        if re.search(r"\brm\b[^\n]*aerc-mail-browser-url", line)
    ]
    assert not offenders, (
        "the launcher deletes the url record, which disables the previous-preview "
        f"reaper: {offenders}"
    )


def recorded(sandbox):
    """The three-line record as it stood while the browser was running."""
    lines = sandbox["record"].read_text().splitlines()
    assert len(lines) == 3, lines
    assert re.fullmatch(r"[1-9][0-9]*", lines[2]), lines
    return lines[0], Path(lines[1]), int(lines[2])


def gone(pid, timeout=5.0):
    """True once `pid` is neither running nor a zombie we have yet to reap.

    kill(2) succeeds on a zombie, so the wait comes first: the server is a
    detached descendant this process subreaps, and reaping it is what makes
    the pid actually disappear.
    """
    deadline = time.monotonic() + timeout
    while True:
        try:
            os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            pass
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        if time.monotonic() > deadline:
            return False
        time.sleep(0.02)


def test_launcher_reaps_the_preview_server_when_the_browser_quits(script, sandbox):
    """Quitting the browser must leave no server, no temp dir and no record.

    With cleanup only in the serve step, one python server and the temp dir
    holding a rendered copy of the mail stayed resident from the moment the
    user quit until the next open.
    """
    assert script, "module defines no aerc-mail-tty script"
    result = subprocess.run(
        ["bash", "-c", runnable(script, sandbox), "aerc-mail-tty",
         str(sandbox["message"])],
        env=sandbox["env"],
        capture_output=True,
        timeout=60,
        check=False,
    )
    print(result.stdout.decode(errors="replace"), flush=True)
    print(result.stderr.decode(errors="replace"), flush=True)
    assert result.returncode == 0, result.stderr.decode(errors="replace")

    url, directory, pid = recorded(sandbox)
    print(f"preview was url={url} dir={directory} pid={pid}", flush=True)
    assert gone(pid), f"preview server {pid} is still alive after the browser quit"
    assert not directory.exists(), f"preview directory survived: {directory}"
    assert not sandbox["urlfile"].exists(), "the url record was left behind"


def test_launcher_reaps_when_the_browser_exits_non_zero(script, sandbox):
    """A browser that dies badly must still be cleaned up after.

    And the status the user sees is the browser's, not the reaper's.
    """
    assert script, "module defines no aerc-mail-tty script"
    result = subprocess.run(
        ["bash", "-c", runnable(script, sandbox), "aerc-mail-tty",
         str(sandbox["message"])],
        env=dict(sandbox["env"], BROWSER_EXIT="3"),
        capture_output=True,
        timeout=60,
        check=False,
    )
    print(result.stdout.decode(errors="replace"), flush=True)
    print(result.stderr.decode(errors="replace"), flush=True)
    assert result.returncode == 3, result.returncode

    url, directory, pid = recorded(sandbox)
    print(f"preview was url={url} dir={directory} pid={pid}", flush=True)
    assert gone(pid), f"preview server {pid} is still alive after a failed browser"
    assert not directory.exists(), f"preview directory survived: {directory}"
    assert not sandbox["urlfile"].exists(), "the url record was left behind"


def test_serve_alone_leaves_its_server_running(sandbox):
    """The detached launchers depend on the server OUTLIVING the serve step.

    aerc-mail-window, -split and -chrome return immediately and the browser
    fetches afterwards, so reaping belongs in the tty launcher's exit path and
    must NOT have moved into serve.
    """
    serve = install(sandbox, "aerc-mail-serve")
    result = subprocess.run(
        [str(serve)],
        input=MESSAGE,
        env=sandbox["env"],
        capture_output=True,
        timeout=60,
        check=False,
    )
    print(result.stderr.decode(errors="replace"), flush=True)
    assert result.returncode == 0, result.stderr.decode(errors="replace")

    lines = sandbox["urlfile"].read_text().splitlines()
    assert len(lines) == 3, lines
    directory, pid = Path(lines[1]), int(lines[2])
    print(f"served url={lines[0]} dir={directory} pid={pid}", flush=True)
    assert directory.is_dir(), f"serve removed its own directory: {directory}"
    os.kill(pid, 0)  # raises ProcessLookupError if serve reaped its own server
    with urlopen(lines[0], timeout=5) as response:
        body = response.read()
    print(f"HTTP {response.status} from {lines[0]}", flush=True)
    assert b"O-TERM FIXTURE" in body, body[:400]


def _run_launcher(script, sandbox, env):
    """Run the launcher to completion and return the environment the browser was given."""
    result = subprocess.run(
        ["bash", "-c", runnable(script, sandbox), "aerc-mail-tty", str(sandbox["message"])],
        env=env,
        capture_output=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    assert sandbox["argv"].exists(), "terminal-browser was never executed"
    return dict(
        line.split("=", 1)
        for line in sandbox["envfile"].read_text().splitlines()
        if "=" in line
    )


def test_launcher_forwards_an_explicit_frame_transport(script, sandbox):
    """AERC_MAIL_FRAMES is passed through, so a remote session can ask for inline pixels.

    terminal-browser picks File/Shared/Inline by probing the terminal, and herdr advertises file
    frames -- so by default the browser writes RGBA into mmap'd ring files under ~/.tmp and hands
    herdr the PATH. Over `herdr --remote` the client cannot read that path, so the pane stays blank
    while the pixels sit in a file nobody opens. Inline is the only transport that survives the hop.
    """
    env = dict(sandbox["env"], AERC_MAIL_FRAMES="inline")
    env_seen = _run_launcher(script, sandbox, env)
    assert env_seen.get("TERMINAL_BROWSER_FRAMES") == "inline", env_seen.get(
        "TERMINAL_BROWSER_FRAMES")


def test_launcher_never_infers_the_transport_from_ssh(script, sandbox):
    """SSH_CONNECTION must NOT force inline: panes inherit the herdr server's env.

    The server is itself started over ssh, so that test is true on the desktop too -- it forced
    inline everywhere, costing the zero-copy file handoff and the eased wheel scrolling with it.
    Only an explicit AERC_MAIL_FRAMES may change the transport.
    """
    env = dict(sandbox["env"], SSH_CONNECTION="10.0.0.1 51000 10.0.0.2 22")
    env.pop("AERC_MAIL_FRAMES", None)
    env_seen = _run_launcher(script, sandbox, env)
    assert "TERMINAL_BROWSER_FRAMES" not in env_seen, env_seen.get("TERMINAL_BROWSER_FRAMES")
