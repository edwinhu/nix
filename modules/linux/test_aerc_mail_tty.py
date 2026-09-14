"""Exercise the Nix-defined `aerc-mail-tty` launcher without building a profile.

Run: python3 -m pytest -q modules/linux/test_aerc_mail_tty.py
The Nix packaging primitives are stubs; the evaluated shell and mail helpers are
real. The launcher is what aerc's `o` runs via :exec-tty, on aerc's OWN
terminal: it must serve the message it was handed and exec terminal-browser on
the served URL, with --no-merge so the browser takes that tty instead of
adopting a neighbour, and with no fallback to a stale URL.
"""

import ctypes
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

FAKE_BROWSER = """#!/usr/bin/env bash
printf '%s\\n' "$@" > "$ARGV_OUT"
env > "$ENV_OUT"
exit 0
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


@pytest.fixture(scope="module")
def serve_text():
    return capture("aerc-mail-serve")


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
            **HERDR_ENV,
        )
        try:
            yield state
        finally:
            _reap(state["urlfile"])


def runnable(script, serve_text, sandbox):
    """Give the launcher a real serve step where the module referenced one."""
    marker = SIBLING + "aerc-mail-serve"
    if marker not in script or not serve_text:
        return script
    path = sandbox["root"] / "aerc-mail-serve"
    path.write_text("#!/usr/bin/env bash\n" + serve_text)
    path.chmod(0o755)
    return script.replace(marker, str(path))


def _reap(urlfile):
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


def test_launcher_serves_and_execs_terminal_browser(script, serve_text, sandbox):
    assert script, "module defines no aerc-mail-tty script"
    result = subprocess.run(
        ["bash", "-c", runnable(script, serve_text, sandbox), "aerc-mail-tty",
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

    with urlopen(urls[0], timeout=5) as response:
        body = response.read()
    print(f"HTTP {response.status} from {urls[0]}", flush=True)
    assert b"O-TERM FIXTURE" in body, body[:400]

    lines = sandbox["urlfile"].read_text().splitlines()
    assert len(lines) == 3, lines
    pid = int(lines[2])
    os.kill(pid, signal.SIGTERM)
    for _ in range(200):
        if not Path(f"/proc/{pid}").exists():
            break
        time.sleep(0.02)
    print(f"server pid={pid} terminated", flush=True)


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


def test_launcher_recovers_seen_renamed_maildir_file(script, serve_text, sandbox):
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
        ["bash", "-c", runnable(script, serve_text, sandbox), "aerc-mail-tty",
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

    with urlopen(urls[0], timeout=5) as response:
        body = response.read()
    print(f"HTTP {response.status} from {urls[0]}", flush=True)
    assert b"SEEN-RENAME FIXTURE" in body, body[:400]


def test_launcher_refuses_when_no_flag_variant_exists(script, serve_text, sandbox):
    """The glob fallback must not rescue a message that is genuinely gone."""
    assert script, "module defines no aerc-mail-tty script"
    maildir = sandbox["root"] / "maildir-empty"
    maildir.mkdir()
    result = subprocess.run(
        ["bash", "-c", runnable(script, serve_text, sandbox), "aerc-mail-tty",
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


def test_launcher_refuses_without_message(script, serve_text, sandbox):
    assert script, "module defines no aerc-mail-tty script"
    missing = sandbox["root"] / "no-such-message.eml"
    result = subprocess.run(
        ["bash", "-c", runnable(script, serve_text, sandbox), "aerc-mail-tty",
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


def test_launcher_never_opens_a_stale_url(script, serve_text, sandbox):
    """An unreadable message must be a visible error, not the previous mail.

    An earlier version fell back to whatever URL the shared file held, so `o`
    on a message aerc had already renamed opened the last thing served -- up to
    and including a test fixture. The launcher must remove that record before
    serving and refuse when it has nothing to serve.
    """
    assert script, "module defines no aerc-mail-tty script"
    sandbox["urlfile"].write_text(f"{STALE_URL}\n/nonexistent-dir\n1\n")

    result = subprocess.run(
        ["bash", "-c", runnable(script, serve_text, sandbox), "aerc-mail-tty",
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


def test_launcher_removes_the_url_file_before_serving(script, serve_text, sandbox):
    """The stale record is dropped, not overwritten in place, before serving."""
    assert script, "module defines no aerc-mail-tty script"
    sandbox["urlfile"].write_text(f"{STALE_URL}\n/nonexistent-dir\n1\n")

    result = subprocess.run(
        ["bash", "-c", runnable(script, serve_text, sandbox), "aerc-mail-tty",
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
