"""Press `o` on a real message in a real aerc, and see what it spawns.

Run through hosts/linux/omarchy/files/test-aerc-o-term.sh, which builds aerc and
the launcher package and exports AERC_BIN and LAUNCHER_BIN. The aerc under test
is a fixture instance: -I, its own accounts file, its own maildir.

The claim being gated is that `o` runs terminal-browser on aerc's OWN terminal
via :exec-tty -- aerc suspends, hands the tty over, and the browser paints
straight to it. So the proof is a descendant of the aerc process, not a
screenshot and not a config grep, followed by graphics arriving on that same
pty.

The bind comes from the real ~/.config/aerc/binds.conf the harness passes with
-B, so this exercises whatever `o` is actually bound to.
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


def test_o_opens_terminal_browser_on_aercs_tty(tmp_path):
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
        session.send("\r")
        assert session.wait_for_text("fixture body text", 30), (
            "the message view never rendered the html part:\n"
            + session.text()[-1500:])

        mark = session.offset()
        session.send("o")

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
            "`o` spawned no terminal-browser under aerc.\n"
            f"descendants seen: {session.descendants()}\n"
            f"last output:\n{session.text()[-1500:]}")
        print(f"terminal-browser descendant: {spawned}", flush=True)

        # :exec-tty's chain is aerc -> aerc-mail-tty -> terminal-browser, and
        # the launcher exec's the browser, so the launcher name survives only in
        # --app-name. Either shape proves it came from the `o` bind rather than
        # some other browser the host had running.
        assert ("aerc-mail-tty" in spawned[1]
                or any("aerc-mail-tty" in cmd
                       for _, cmd in session.descendants())), (
            "terminal-browser did not come from the aerc-mail-tty launcher:\n"
            f"{session.descendants()}")

        # The browser has aerc's OWN terminal now, so its graphics arrive on
        # this pty directly -- kitty when it falls back to inline frames, sixel
        # when the terminal reports only that.
        deadline = time.monotonic() + 20
        frame = None
        while time.monotonic() < deadline and frame is None:
            frame = next((c for c in session.kitty_commands(mark)
                          if b"a=T" in c), None)
            if frame is None and b"\x1bP" in session.raw()[mark:]:
                frame = b"<sixel/DCS payload>"
            if frame is None:
                time.sleep(0.25)
        assert frame is not None, (
            "no graphics reached the terminal after `o`.\n"
            f"kitty commands seen: "
            f"{[c[:60] for c in session.kitty_commands(mark)]}\n"
            f"last output:\n{session.text()[-1500:]}")
        print(f"frame: {frame[:80]!r}", flush=True)

        session.send("q")
        time.sleep(2)
    finally:
        session.close()
