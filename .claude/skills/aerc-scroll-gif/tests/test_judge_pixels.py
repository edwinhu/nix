"""Contract for judge-pixels.py — tap → first changed pixel, from a real recording.

Run: python3 -m pytest -q .claude/skills/aerc-scroll-gif/tests/test_judge_pixels.py

These tests build REAL mp4s with ffmpeg whose content changes at known offsets and assert the judge
recovers those offsets. Nothing here mocks ffprobe: the whole point of this instrument is that it
measures pixels that actually reached the screen, and a mocked decoder would pass just as happily
against a judge that measured nothing at all.

Fixtures are synthesised in-test, per this repo's habit (hosts/linux/omarchy/files/test_preview_reap.py).
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
JUDGE = HERE.parent / "scripts" / "judge-pixels.py"

FPS = 60
FRAME_MS = 1000.0 / FPS

pytestmark = pytest.mark.skipif(
    shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None,
    reason="ffmpeg/ffprobe are required: this suite measures real video, it does not mock a decoder",
)


def make_video(path: Path, segments, fps: int = FPS) -> Path:
    """Render `segments` -- [(colour, seconds), ...] -- as one mp4 with hard cuts between them.

    A hard cut is a scene change of ~1.0, which is what the ffprobe scene-select idiom in
    record-scroll.sh:151 reports as a changed frame.
    """
    inputs, filters = [], []
    for i, (colour, secs) in enumerate(segments):
        inputs += ["-f", "lavfi", "-i", f"color=c={colour}:s=320x240:r={fps}:d={secs}"]
        filters.append(f"[{i}:v]")
    cmd = (
        ["ffmpeg", "-y", "-v", "error", *inputs, "-filter_complex",
         "".join(filters) + f"concat=n={len(segments)}:v=1:a=0[out]",
         "-map", "[out]", "-pix_fmt", "yuv420p", "-r", str(fps), str(path)]
    )
    subprocess.run(cmd, check=True, capture_output=True)
    assert path.stat().st_size > 0, "ffmpeg produced an empty video"
    return path


def run_judge(video: Path, start_epoch: float, lat_max_ms: int, taps):
    argv = [sys.executable, str(JUDGE), str(video), f"{start_epoch:.6f}", str(lat_max_ms)]
    argv += [f"{t:.6f}" for t in taps]
    return subprocess.run(argv, capture_output=True, text=True, check=False)


def per_tap(stdout: str):
    m = re.search(r"^latency ms per tap: (.*)$", stdout, re.MULTILINE)
    assert m, f"no 'latency ms per tap:' line in output:\n{stdout}"
    out = []
    for tok in m.group(1).split():
        out.append(None if tok == "none" else int(tok))
    return out


def median_of(stdout: str):
    m = re.search(r"^median key→frame ms: (\S+)$", stdout, re.MULTILINE)
    assert m, f"no median line in output:\n{stdout}"
    return None if m.group(1) == "none" else int(m.group(1))


def test_known_offset_is_recovered_within_one_frame(tmp_path):
    """A tap 400 ms before the only change must measure 400 ms, not 0 and not 'none'.

    This is the test the whole instrument exists to pass: it is the one that fails if the judge
    reports the time of any frame rather than the first CHANGED frame after the tap.
    """
    video = make_video(tmp_path / "cut.mp4", [("black", 1.0), ("white", 1.0)])
    start = 1_000_000.0
    tap = start + 0.6           # the cut lands at t=1.0s → 400 ms later
    r = run_judge(video, start, 200, [tap])
    assert r.returncode in (0, 1, 2), f"judge failed to run: {r.returncode}\n{r.stderr}"
    (measured,) = per_tap(r.stdout)
    assert measured is not None, f"tap reported 'none' though the video changes 400 ms later\n{r.stdout}"
    assert abs(measured - 400) <= FRAME_MS + 1, f"expected ~400 ms, got {measured} ms\n{r.stdout}"


def test_tap_after_the_last_change_is_none(tmp_path):
    """Nothing repaints after this tap, so there is no latency to report -- that is 'none'.

    'none' must mean 'no frame followed', never 'zero ms'. Collapsing the two is how a broken
    viewer scores well.
    """
    video = make_video(tmp_path / "cut.mp4", [("black", 1.0), ("white", 2.0)])
    start = 1_000_000.0
    tap = start + 2.0           # the only cut was at 1.0s; nothing changes after 2.0s
    r = run_judge(video, start, 200, [tap])
    (measured,) = per_tap(r.stdout)
    assert measured is None, f"expected 'none' after the last change, got {measured} ms\n{r.stdout}"


def test_all_taps_unmeasured_exits_3(tmp_path):
    """Every tap outside the window is 'unmeasured' (exit 3), never a verdict on the viewer.

    judge-taps.py:39-42 draws this line, and check-latency-built.sh's callers rely on 3 meaning
    'the measurement did not happen' rather than 'the viewer is slow'.
    """
    video = make_video(tmp_path / "static.mp4", [("black", 1.0), ("white", 1.0)])
    start = 1_000_000.0
    taps = [start + 5.0, start + 6.0]       # long past the end of a 2 s video
    r = run_judge(video, start, 200, taps)
    assert r.returncode == 3, f"expected exit 3 unmeasured, got {r.returncode}\n{r.stdout}\n{r.stderr}"
    assert median_of(r.stdout) is None


def test_verdict_thresholds_follow_the_judge_taps_contract(tmp_path):
    """0 fast / 1 sluggish / 2 laggy, on the same boundaries as judge-taps.py:45-50.

    check-latency-built.sh execs straight through to this exit code and six archived craft plans
    name the contract, so the numbers are not ours to re-pick.
    """
    video = make_video(tmp_path / "cut.mp4", [("black", 1.0), ("white", 1.0)])
    start = 1_000_000.0
    tap = start + 0.6                       # ~400 ms
    fast = run_judge(video, start, 500, [tap])          # 400 <= 500
    sluggish = run_judge(video, start, 250, [tap])      # 250 < 400 <= 437.5
    laggy = run_judge(video, start, 200, [tap])         # 400 > 350
    assert fast.returncode == 0, f"400 ms against a 500 ms budget is fast\n{fast.stdout}"
    assert sluggish.returncode == 1, f"400 ms against a 250 ms budget is sluggish\n{sluggish.stdout}"
    assert laggy.returncode == 2, f"400 ms against a 200 ms budget is laggy\n{laggy.stdout}"
    assert "verdict:" in laggy.stdout


def test_median_uses_the_upper_value_on_an_even_count(tmp_path):
    """sorted[len//2], matching judge-taps.py:43 exactly -- not a mean, not the lower median.

    Two judges reporting the same run must not disagree because they broke a tie differently.
    """
    video = make_video(tmp_path / "cuts.mp4", [("black", 1.0), ("white", 1.0), ("black", 1.0)])
    start = 1_000_000.0
    taps = [start + 0.9, start + 1.5]       # ~100 ms and ~500 ms → upper median is 500
    r = run_judge(video, start, 200, taps)
    measured = [m for m in per_tap(r.stdout) if m is not None]
    assert len(measured) == 2, f"expected two measured taps, got {per_tap(r.stdout)}\n{r.stdout}"
    assert median_of(r.stdout) == max(measured), (
        f"even count must take the upper median {max(measured)}, got {median_of(r.stdout)}"
    )


def test_output_lines_match_the_shape_callers_grep_for(tmp_path):
    """record-scroll.sh:130-131 greps these three lines out of stdout with regexes.

    A judge that computes correctly and prints differently breaks the harness just as completely.
    """
    video = make_video(tmp_path / "cut.mp4", [("black", 1.0), ("white", 1.0)])
    start = 1_000_000.0
    r = run_judge(video, start, 200, [start + 0.6])
    assert re.search(r"^latency ms per tap: [\d ]*(?:none|\d)[\d none]*$", r.stdout, re.MULTILINE), r.stdout
    assert re.search(r"^median key→frame ms: \d+$", r.stdout, re.MULTILINE), r.stdout
    assert re.search(r"^verdict: (fast|sluggish|laggy) \(median \d+ ms vs \d+ ms; exit \d\)$",
                     r.stdout, re.MULTILINE), r.stdout
