"""Press `o` on a real message in a real aerc, and see what it spawns.

Run through hosts/linux/omarchy/files/test-aerc-o-term.sh, which builds aerc and
the launcher package and exports AERC_BIN and LAUNCHER_BIN. The aerc under test
is a fixture instance: -I, its own accounts file, its own maildir.

The claim being gated is that `o` runs terminal-browser INSIDE aerc's embedded
terminal -- so the proof is a descendant of the aerc process, not a screenshot
and not a config grep, followed by kitty frames relayed back to the host.
"""

import os
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from aerc_o_term_harness import Session, build_fixture


def _binary(name, expect_dir=False):
    value = os.environ.get(name)
    if not value:
        pytest.fail(f"{name} is not set -- run hosts/linux/omarchy/files/"
                    f"test-aerc-o-term.sh, which builds it and exports it")
    path = Path(value)
    if expect_dir:
        if not path.is_dir():
            pytest.fail(f"{name}={value} is not a directory")
    elif not os.access(path, os.X_OK):
        pytest.fail(f"{name}={value} is not an executable file")
    return path


def _await_browser(session, timeout=30, exclude_pid=None):
    """First terminal-browser descendant of aerc, or None if none appears."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        spawned = next(
            ((pid, cmd) for pid, cmd in session.descendants()
             if "terminal-browser" in cmd and pid != exclude_pid), None)
        if spawned is not None:
            return spawned
        time.sleep(0.25)
    return None


def _await_frame(session, mark, timeout=20):
    """First kitty transmit-and-display command emitted after `mark`."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        frame = next((c for c in session.kitty_commands(mark)
                      if b"a=T" in c), None)
        if frame is not None:
            return frame
        time.sleep(0.25)
    return None


def test_o_opens_terminal_browser_inside_term(tmp_path):
    """`o` is the ESCAPE HATCH back to the browser once the viewer is showing.

    Enter is now the default: it chains `:view` and `:term`, so the browser is
    what comes up first and the chawan viewer is never painted between the two.
    Quitting the browser with `q` closes the :term tab and drops back to the
    viewer -- and from THERE `o` must open a browser again, as a second,
    distinct process.
    """
    aerc = _binary("AERC_BIN")
    launcher = _binary("LAUNCHER_BIN", expect_dir=True)

    accounts = build_fixture(tmp_path)
    session = Session().start(
        aerc, accounts, cols=120, rows=40, xpx=1920, ypx=1280,
        responder=True,
        extra_env={"PATH": str(launcher) + os.pathsep + os.environ["PATH"]},
    )
    try:
        assert session.wait_for_text("O-TERM FIXTURE", 30), (
            "aerc never showed the fixture subject:\n" + session.text()[-1500:])

        # 1. Enter -- the default view -- brings up the browser.
        mark = session.offset()
        session.send("\r")

        first = _await_browser(session, 30)
        assert first is not None, (
            "`<Enter>` spawned no terminal-browser under aerc.\n"
            f"descendants seen: {session.descendants()}\n"
            f"last output:\n{session.text()[-1500:]}")
        print(f"first terminal-browser descendant: {first}", flush=True)

        frame = _await_frame(session, mark, 20)
        assert frame is not None, (
            "no kitty transmit-and-display command reached the host after "
            "`<Enter>`.\n"
            f"kitty commands seen: "
            f"{[c[:60] for c in session.kitty_commands(mark)]}\n"
            f"last output:\n{session.text()[-1500:]}")
        print(f"first kitty frame: {frame[:80]!r}", flush=True)

        # 2. q -- the launcher's preload binds it to terminalBrowser.quit() --
        #    closes the browser, the :term tab goes away and the chawan viewer
        #    underneath becomes visible.
        #    The preload only sees a keydown once the page has focus, and the
        #    first kitty frame lands before that -- a single `q` sent right
        #    after it is dropped. Repeat it across the budget, as a human does.
        deadline = time.monotonic() + 15
        gone = False
        next_press = 0.0
        while time.monotonic() < deadline:
            if time.monotonic() >= next_press:
                session.send("q")
                next_press = time.monotonic() + 3
            if not any(pid == first[0] for pid, _ in session.descendants()):
                gone = True
                break
            time.sleep(0.25)
        assert gone, (
            f"`q` did not end the first terminal-browser (pid {first[0]}).\n"
            f"descendants seen: {session.descendants()}\n"
            f"last output:\n{session.text()[-1500:]}")

        assert session.wait_for_text("fixture body text", 45), (
            "the chawan viewer never became visible after quitting the "
            "browser:\n" + session.text()[-1500:])

        # 3. o -- from the viewer -- must bring up a NEW browser.
        mark = session.offset()
        session.send("o")

        second = _await_browser(session, 30, exclude_pid=first[0])
        assert second is not None, (
            "`o` spawned no second terminal-browser under aerc.\n"
            f"first was {first}\n"
            f"descendants seen: {session.descendants()}\n"
            f"last output:\n{session.text()[-1500:]}")
        assert second[0] != first[0], (
            f"`o` did not spawn a new process: {second} is the first one.\n"
            f"last output:\n{session.text()[-1500:]}")
        print(f"second terminal-browser descendant: {second}", flush=True)

        frame = _await_frame(session, mark, 20)
        assert frame is not None, (
            "no kitty transmit-and-display command reached the host after "
            "`o`.\n"
            f"kitty commands seen: "
            f"{[c[:60] for c in session.kitty_commands(mark)]}\n"
            f"last output:\n{session.text()[-1500:]}")
        print(f"second kitty frame: {frame[:80]!r}", flush=True)

        session.send("q")
        time.sleep(2)
    finally:
        session.close()


def test_enter_opens_terminal_browser_inside_term(tmp_path):
    """ONE keypress -- Enter in [messages] -- must reach terminal-browser.

    Red today: [messages] <Enter> is `:view`, so nothing spawns and the
    `spawned is not None` assertion fires.
    """
    aerc = _binary("AERC_BIN")
    launcher = _binary("LAUNCHER_BIN", expect_dir=True)

    accounts = build_fixture(tmp_path)
    session = Session().start(
        aerc, accounts, cols=120, rows=40, xpx=1920, ypx=1280,
        responder=True,
        extra_env={"PATH": str(launcher) + os.pathsep + os.environ["PATH"]},
    )
    try:
        assert session.wait_for_text("O-TERM FIXTURE", 30), (
            "aerc never showed the fixture subject:\n" + session.text()[-1500:])

        mark = session.offset()
        session.send("\r")

        deadline = time.monotonic() + 30
        spawned = None
        while time.monotonic() < deadline and spawned is None:
            children = session.descendants()
            spawned = next(
                ((pid, cmd) for pid, cmd in children
                 if "terminal-browser" in cmd), None)
            if spawned is None:
                time.sleep(0.25)
        assert spawned is not None, (
            "`<Enter>` spawned no terminal-browser under aerc.\n"
            f"descendants seen: {session.descendants()}\n"
            f"last output:\n{session.text()[-1500:]}")
        print(f"terminal-browser descendant: {spawned}", flush=True)

        deadline = time.monotonic() + 20
        frame = None
        while time.monotonic() < deadline and frame is None:
            frame = next((c for c in session.kitty_commands(mark)
                          if b"a=T" in c), None)
            if frame is None:
                time.sleep(0.25)
        assert frame is not None, (
            "no kitty transmit-and-display command reached the host after "
            "`<Enter>`.\n"
            f"kitty commands seen: "
            f"{[c[:60] for c in session.kitty_commands(mark)]}\n"
            f"last output:\n{session.text()[-1500:]}")
        print(f"kitty frame: {frame[:80]!r}", flush=True)

        session.send("q")
        time.sleep(2)
    finally:
        session.close()


def test_enter_on_plaintext_opens_no_browser(tmp_path):
    """A plain-text message must open exactly as today: the colorize viewer,
    no browser.

    GREEN today and must stay green -- this is a regression guard, not a red
    test. Nothing spawns a browser now; it goes red only against an
    implementation that routes the plain-text path through the browser too.
    The positive half (`plain fixture body` painted) is what keeps it from
    being a tautology.
    """
    aerc = _binary("AERC_BIN")
    launcher = _binary("LAUNCHER_BIN", expect_dir=True)

    accounts = build_fixture(tmp_path, html=False)
    session = Session().start(
        aerc, accounts, cols=120, rows=40, xpx=1920, ypx=1280,
        responder=True,
        extra_env={"PATH": str(launcher) + os.pathsep + os.environ["PATH"]},
    )
    try:
        assert session.wait_for_text("PLAIN FIXTURE", 30), (
            "aerc never showed the plain fixture subject:\n"
            + session.text()[-1500:])
        session.send("\r")
        assert session.wait_for_text("plain fixture body", 30), (
            "the message view never rendered the plain text part:\n"
            + session.text()[-1500:])

        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            spawned = next(
                ((pid, cmd) for pid, cmd in session.descendants()
                 if "terminal-browser" in cmd), None)
            assert spawned is None, (
                "`<Enter>` on a plain-text message spawned a browser:\n"
                f"{spawned}\n"
                f"last output:\n{session.text()[-1500:]}")
            time.sleep(0.25)
    finally:
        session.close()
