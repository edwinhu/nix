"""Run: python3 -m pytest -q hosts/linux/omarchy/files/test_mbsync_guarded.py"""
import importlib.util
import stat
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("guarded", HERE / "mbsync-guarded.py")
assert spec and spec.loader
guarded = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guarded)


def maildir(root, box, pairs):
    """pairs: (far_uid, near_uid, recorded_flags, local_flags)"""
    d = root / box
    for sub in ("cur", "new", "tmp"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    lines = ["FarUidValidity 1", "NearUidValidity 1", "MaxPulledUid 9", "MaxPushedUid 9", ""]
    for far, near, recorded, local in pairs:
        (d / "cur" / f"1.{near}_1.host,U={near}:2,{local}").write_text("x")
        lines.append(f"{far} {near} {recorded}".rstrip())
    (d / ".mbsyncstate").write_text("\n".join(lines) + "\n")


def fake(path, log):
    path.write_text(f'#!/bin/sh\necho "$@" >> {log}\n')
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return str(path)


def run(tmp_path, monkeypatch, pairs):
    root = tmp_path / "mail"
    maildir(root, "work/INBOX", pairs)
    (root / "personal").mkdir(parents=True)
    monkeypatch.setattr(guarded, "ROOT", str(root))
    log = tmp_path / "calls"
    mbsync = fake(tmp_path / "mbsync", log)
    notmuch = fake(tmp_path / "notmuch", log)
    assert guarded.main(["x", mbsync, "rc", notmuch, "work"]) == 0
    return log.read_text().splitlines()


def test_counts_only_seen_lost_locally(tmp_path):
    root = tmp_path / "work"
    maildir(root, "INBOX", [(1, 1, "S", ""), (2, 2, "S", "S"), (3, 3, "", ""), (4, 4, "", "S"),
                            (5, 5, "FS", "F"),
                            # far UID 0: gone upstream, nothing to push to
                            (0, 6, "S", "T")])
    assert guarded.pending_unread_pushes(str(root)) == 2


def test_pushes_normally_under_the_limit(tmp_path, monkeypatch):
    calls = run(tmp_path, monkeypatch, [(1, 1, "S", ""), (2, 2, "", "S")])
    assert calls[0] == "--config rc work"
    assert calls[1] == "new --quiet"


def test_pulls_only_when_many_read_messages_lost_seen(tmp_path, monkeypatch):
    lost = [(n, n, "S", "") for n in range(1, guarded.UNREAD_PUSH_LIMIT + 2)]
    calls = run(tmp_path, monkeypatch, lost)
    assert calls[0] == "--config rc --pull work"
    assert calls[1] == "new --quiet"
