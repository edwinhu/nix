"""The gate scripts decide everything, and until now nothing tested them.

Every wrong answer this instrument gave came from its verdict logic, not from the pipeline it
measures: a zero-count trace crashing on `0\\n0`, zero transmits reported as could-not-run when it
is the goal, a crashed test window scored as the product failing. These tests pin the decisions
themselves, extracted from the scripts so the real text is exercised rather than a copy.
"""
import re
import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


def _last_py_block(script: Path) -> str:
    """The verdict heredoc is the LAST `<<'PY'` block; the first is the fixture generator."""
    blocks = re.findall(r"<<'PY'\n(.*?)\nPY\n", script.read_text(), re.S)
    assert blocks, f"no python heredoc in {script.name}"
    return blocks[-1]


def _run(body: str, args, tmp_path) -> subprocess.CompletedProcess:
    prog = tmp_path / "verdict.py"
    prog.write_text(body)
    return subprocess.run([sys.executable, str(prog), *args], capture_output=True, text=True)


def test_zero_transmits_on_the_direct_path_is_success(tmp_path):
    """Zero pty transmits is the GOAL once direct-kitty is live, not a failed measurement."""
    trace = tmp_path / "empty.trace"
    trace.write_text("")
    body = _last_py_block(SCRIPTS / "check-scroll-bytes.sh")
    r = _run(body, [str(trace), "0", "100.0", "107.0", "3", "2400", "direct-kitty"], tmp_path)
    assert r.returncode == 0, f"expected success, got {r.returncode}: {r.stdout}{r.stderr}"


def test_zero_transmits_without_the_direct_path_is_unmeasured(tmp_path):
    """The same empty trace with no transport means nothing painted: could-not-run, not success."""
    trace = tmp_path / "empty.trace"
    trace.write_text("")
    body = _last_py_block(SCRIPTS / "check-scroll-bytes.sh")
    r = _run(body, [str(trace), "0", "100.0", "107.0", "3", "2400", ""], tmp_path)
    assert r.returncode == 3, f"expected could-not-run, got {r.returncode}: {r.stdout}{r.stderr}"


def test_amplification_over_budget_fails(tmp_path):
    """A real trace above the budget must fail, or the gate gates nothing."""
    trace = tmp_path / "busy.trace"
    trace.write_text("".join(
        'write(84, "\\33_Ga=T,f=32,s=1984,v=1188,t=f,i=1,p=1,C=1,q=2;xx", 135) = 135\n'
        for _ in range(24)))
    body = _last_py_block(SCRIPTS / "check-scroll-bytes.sh")
    r = _run(body, [str(trace), "0", "100.0", "101.34", "3", "2400", ""], tmp_path)
    assert r.returncode == 1, f"expected over-budget failure, got {r.returncode}: {r.stdout}"
    assert "amplification" in r.stdout


def test_amplification_under_budget_passes(tmp_path):
    """And a trace inside the budget must pass, so the threshold is real in both directions."""
    trace = tmp_path / "light.trace"
    trace.write_text(
        'write(84, "\\33_Ga=T,f=32,s=1984,v=1188,t=f,i=1,p=1,C=1,q=2;xx", 135) = 135\n')
    body = _last_py_block(SCRIPTS / "check-scroll-bytes.sh")
    r = _run(body, [str(trace), "0", "100.0", "101.34", "3", "2400", ""], tmp_path)
    assert r.returncode == 0, f"expected pass, got {r.returncode}: {r.stdout}"
