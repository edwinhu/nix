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


# --- locking: per-account mbsync, shared lock excludes the taggers ---------

import fcntl
import os
import threading
import time


def lock_probe(path, lockfile, log):
    """A fake mbsync that records whether an EXCLUSIVE lock on `lockfile` (what a
    tagger's `flock -w 120` takes) could be had while it ran, then its argv."""
    path.write_text(
        "#!/bin/sh\n"
        f'if flock -n -x {lockfile} true; then echo tagger-free >> {log}; '
        f'else echo tagger-excluded >> {log}; fi\n'
        f'echo "$@" >> {log}\n'
    )
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return str(path)


def setup(tmp_path, monkeypatch):
    root = tmp_path / "mail"
    for acct in ("work", "personal"):
        maildir(root, f"{acct}/INBOX", [(1, 1, "S", "S")])
    monkeypatch.setattr(guarded, "ROOT", str(root))
    log = tmp_path / "calls"
    mbsync = lock_probe(tmp_path / "mbsync", root / ".mbsync.lock", log)
    notmuch = fake(tmp_path / "notmuch", log)
    return root, log, mbsync, notmuch


def hold(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def test_busy_personal_sync_does_not_stop_work(tmp_path, monkeypatch):
    root, log, mbsync, notmuch = setup(tmp_path, monkeypatch)
    fd = hold(root / ".mbsync-personal.lock")
    try:
        assert guarded.main(["x", mbsync, "rc", notmuch, "mail"]) == 0
    finally:
        os.close(fd)
    calls = log.read_text().splitlines()
    assert "--config rc work" in calls
    assert not any(c.endswith(" personal") or c.endswith(" mail") for c in calls)


def test_taggers_are_excluded_while_mbsync_runs(tmp_path, monkeypatch):
    root, log, mbsync, notmuch = setup(tmp_path, monkeypatch)
    assert guarded.main(["x", mbsync, "rc", notmuch, "work"]) == 0
    calls = log.read_text().splitlines()
    assert calls[0] == "tagger-excluded"
    assert calls[1] == "--config rc work"
    assert "new --quiet" in calls


def test_two_accounts_can_sync_at_once(tmp_path, monkeypatch):
    root, log, mbsync, notmuch = setup(tmp_path, monkeypatch)
    # Another account's sync holds the shared lock in SHARED mode; this one must
    # still get in rather than queue behind it.
    fd = os.open(root / ".mbsync.lock", os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
    try:
        assert guarded.main(["x", mbsync, "rc", notmuch, "work", "--wait", "2"]) == 0
    finally:
        os.close(fd)
    assert "--config rc work" in log.read_text().splitlines()


def test_wait_queues_behind_a_busy_account_instead_of_dropping(tmp_path, monkeypatch):
    root, log, mbsync, notmuch = setup(tmp_path, monkeypatch)
    fd = hold(root / ".mbsync-work.lock")
    threading.Timer(0.5, os.close, args=(fd,)).start()
    started = time.monotonic()
    assert guarded.main(["x", mbsync, "rc", notmuch, "work", "--wait", "10"]) == 0
    assert time.monotonic() - started >= 0.4
    assert "--config rc work" in log.read_text().splitlines()


def test_without_wait_a_busy_account_is_skipped(tmp_path, monkeypatch):
    root, log, mbsync, notmuch = setup(tmp_path, monkeypatch)
    fd = hold(root / ".mbsync-work.lock")
    try:
        assert guarded.main(["x", mbsync, "rc", notmuch, "work"]) == 0
    finally:
        os.close(fd)
    assert not log.exists() or "--config rc work" not in log.read_text().splitlines()
