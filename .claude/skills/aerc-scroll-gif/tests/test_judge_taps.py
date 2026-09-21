"""Regression pin for judge-taps.py, the AUXILIARY announcement metric.

Run: python3 -m pytest -q .claude/skills/aerc-scroll-gif/tests/test_judge_taps.py

This file once demanded ring-path de-duplication, on the theory that terminal-browser re-announces
the same mmap'd .rgba buffer many times per repaint. **That theory was refuted against the captured
trace**: of 66 a=T writes over 8 distinct paths, there were 0 consecutive repeats and 65 path
changes — the ring cycles -0..-7 strictly, so "8 distinct paths" is buffer REUSE, not repetition,
and previous-path dedupe would have turned 66 frames into 65. Two independent implementers reported
the same wall before anything was loosened to make it pass.

So judge-taps.py keeps counting every a=T, and these tests exist to pin the behaviour it already
has — the exit contract that check-latency-built.sh execs through, the herdr rgba-JSON sink path,
and robustness against strace's -s 120 truncation. Ground truth now lives in judge-pixels.py, which
measures pixels that actually reached the screen; this metric is reported beside it, never as the
verdict.

Fixtures are synthesised strace text, per this repo's habit of constructing fixtures in-test.
"""

import base64
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
JUDGE = HERE.parent / "scripts" / "judge-taps.py"

RING = "/home/eh/.tmp/terminal-browser-1923415-0-0-{n}.rgba"
PID = 1923415


def a_t_line(t: float, ring_n: int, pid: int = PID) -> str:
    """One strace -f -tt write line carrying a kitty file-transmit for ring slot `ring_n`.

    Mirrors a real captured line, including the -s 120 truncation: strace clips the string and
    appends '...', so the base64 tail is usually missing and a judge must not require a clean
    decode.
    """
    payload = base64.b64encode(RING.format(n=ring_n).encode()).decode()
    body = f'\\33[?2026h\\33[H\\33_Ga=T,f=32,s=2016,v=1944,t=f,i=1,p=1,C=1,q=2;{payload}'
    hh = int(t // 3600) % 24
    mm = int(t // 60) % 60
    ss = t % 60
    return f'{pid} {hh:02d}:{mm:02d}:{ss:09.6f} write(81, "{body[:120]}"..., 135) = 135\n'


def write_trace(path: Path, events) -> Path:
    """events: [(offset_seconds, ring_slot), ...] relative to a fixed wall-clock base."""
    base = 13 * 3600 + 50 * 60          # 13:50:00, matching the captured run
    path.write_text("".join(a_t_line(base + off, n) for off, n in events))
    return path


def run_judge(trace: Path, lat_max_ms: int, taps):
    argv = [sys.executable, str(JUDGE), str(trace), str(lat_max_ms)] + [f"{t:.6f}" for t in taps]
    return subprocess.run(argv, capture_output=True, text=True, check=False)


def epoch_for(offset: float) -> float:
    """The judge reconstructs wall-clock from the first tap's local date, so taps and trace lines
    must agree on the same day. Build tap epochs from the same base the fixture uses."""
    import datetime as dt
    base = (dt.datetime.now(tz=dt.timezone.utc).astimezone()
            .replace(hour=13, minute=50, second=0, microsecond=0))
    return base.timestamp() + offset


def per_tap(stdout: str):
    m = re.search(r"^latency ms per tap: (.*)$", stdout, re.MULTILINE)
    assert m, f"no per-tap line in output:\n{stdout}"
    return [None if tok == "none" else int(tok) for tok in m.group(1).split()]




def test_a_new_slot_after_the_tap_is_a_frame(tmp_path):
    """The positive case: the ring advances, so pixels changed, so the tap was served.

    Without this, 'count nothing' would pass the suite.
    """
    trace = write_trace(tmp_path / "trace.txt", [
        (0.00, 0),
        (1.30, 1),      # 300 ms after the tap below, the ring advances
    ])
    r = run_judge(trace, 200, [epoch_for(1.00)])
    (measured,) = per_tap(r.stdout)
    assert measured is not None, f"an advanced ring slot is a real frame\n{r.stdout}"
    assert 250 <= measured <= 350, f"expected ~300 ms, got {measured} ms\n{r.stdout}"


def test_truncated_base64_never_crashes(tmp_path):
    """strace -s 120 clips the payload, so most captured lines carry an undecodable tail.

    The judge must compare on the captured prefix and keep going; a traceback here would make
    every real trace unmeasurable.
    """
    trace = write_trace(tmp_path / "trace.txt", [(0.00, 0), (1.30, 1)])
    mangled = trace.read_text().replace("q=2;", "q=2;!!!not-base64!!!")
    trace.write_text(mangled)
    r = run_judge(trace, 200, [epoch_for(1.00)])
    assert "Traceback" not in r.stderr, f"judge crashed on a truncated payload:\n{r.stderr}"
    assert r.returncode in (0, 1, 2, 3), f"unexpected exit {r.returncode}\n{r.stderr}"


def test_exit_contract_and_output_shape_are_unchanged(tmp_path):
    """argv, the three stdout lines and 0/1/2/3 are load-bearing.

    check-latency-built.sh:13 execs straight through this exit code, record-scroll.sh:130-131 greps
    these lines, and six archived craft plans name the contract.
    """
    trace = write_trace(tmp_path / "trace.txt", [(0.00, 0), (1.30, 1)])
    laggy = run_judge(trace, 100, [epoch_for(1.00)])    # ~300 ms vs 100 ms budget
    assert laggy.returncode == 2, f"expected laggy exit 2, got {laggy.returncode}\n{laggy.stdout}"
    assert re.search(r"^latency ms per tap: ", laggy.stdout, re.MULTILINE), laggy.stdout
    assert re.search(r"^median key→frame ms: \d+$", laggy.stdout, re.MULTILINE), laggy.stdout
    assert re.search(r"^verdict: laggy \(median \d+ ms vs \d+ ms; exit 2\)$",
                     laggy.stdout, re.MULTILINE), laggy.stdout
    empty = run_judge(write_trace(tmp_path / "empty.txt", []), 200, [epoch_for(1.0)])
    assert empty.returncode == 3, f"a trace with no frames is unmeasured (exit 3), got {empty.returncode}"


def test_herdr_sink_rgba_json_still_counts(tmp_path):
    """The herdr pane.graphics.stream path (line 24's rgba-JSON spellings) must keep working.

    That sink is a different transport for the same frames, and no change to the kitty-ring side of
    this judge may silently delete support for it.
    """
    base = 13 * 3600 + 50 * 60
    hh, mm = 13, 50
    line = (f'{PID} {hh:02d}:{mm:02d}:01.000000 write(9, '
            f'"{{\\"method\\":\\"pane.graphics.stream\\",\\"format\\":\\"rgba\\"}}", 64) = 64\n')
    trace = tmp_path / "trace.txt"
    trace.write_text(line)
    assert base  # the fixture's wall-clock base, kept explicit for readability
    r = run_judge(trace, 2000, [epoch_for(0.90)])
    (measured,) = per_tap(r.stdout)
    assert measured is not None, (
        f"an rgba stream header is still a frame on the herdr sink path\n{r.stdout}"
    )
