"""Judge a herdr-surface run from `strace -f -tt -e read,write` of aerc plus the egress verdict:
did the ↓ repeats reach the child evenly during the hold, and did any a=T escape cross the pty?
Usage: judge-herdr-keys.py <trace.txt> <verdict.json> [min_keys=60] [max_gap_ms=300]
Exit 0 pass, 4 fail (bunched keys / frames on the pty), 3 unmeasured."""

import json
import re
import sys

trace, verdict = sys.argv[1], sys.argv[2]
min_keys = int(sys.argv[3]) if len(sys.argv) > 3 else 60
max_gap = float(sys.argv[4]) if len(sys.argv) > 4 else 300.0

head_re = re.compile(r"^(\d+) +(\d\d):(\d\d):(\d\d\.\d+) (.*)$")
call_re = re.compile(r'^(read|write)\((\d+)(?:, "(.*?)"(?:\.\.\.)?, \d+)?(?: <unfinished \.\.\.>|\) = (-?\d+))')
res_re = re.compile(r'^<\.\.\. (read|write) resumed>(?:, "(.*?)"(?:\.\.\.)?, \d+)?\) = (-?\d+)')
down_re = re.compile(r"\x1b\[(?:1;[\d:]+)?B|\x1bOB")


def unesc(s):
    return s.encode("latin1", "backslashreplace").decode("unicode_escape", errors="replace")


pending, ev = {}, []
with open(trace, errors="replace") as fh:
    for line in fh:
        h = head_re.match(line.rstrip("\n"))
        if not h:
            continue
        tid, rest = h.group(1), h.group(5)
        t = int(h.group(2)) * 3600 + int(h.group(3)) * 60 + float(h.group(4))
        c = call_re.match(rest)
        if c:
            call, fd, data = c.group(1), int(c.group(2)), unesc(c.group(3) or "")
            if "<unfinished" in rest:
                pending[tid] = (call, fd, t, data)
            else:
                ev.append((t, call, fd, data))
            continue
        r = res_re.match(rest)
        if r:
            p = pending.pop(tid, None)
            ev.append((t, r.group(1), p[1] if p else -1, unesc(r.group(2) or "") or (p[3] if p else "")))
ev.sort()
child_fds = [fd for _, c, fd, d in ev if c == "write" and down_re.search(d)]
if not child_fds:
    print("unmeasured: no Down key writes in the trace")
    sys.exit(3)
child_fd = max(set(child_fds), key=child_fds.count)
keys = [t for t, c, fd, d in ev if c == "write" and fd == child_fd for _ in down_re.findall(d)]
frames_pty = 0
try:
    with open(verdict) as fh:
        frames_pty = int(json.load(fh).get("frames", 0))
except (OSError, ValueError):
    print("unmeasured: no verdict.json from the egress harness")
    sys.exit(3)
# The hold is the densest 3 s window of key writes.
best = 0
for i, t0 in enumerate(keys):
    n = sum(1 for t in keys[i:] if t - t0 <= 3.0)
    best = max(best, n)
gaps = [round((b - a) * 1000) for a, b in zip(keys, keys[1:])]
hold_gaps = [g for g in gaps if g < 2500]  # ignore the pause before the hold
worst = max(hold_gaps) if hold_gaps else 0
print(f"Down keys to child: {len(keys)} total, {best} in the densest 3 s; worst gap {worst} ms; a=T escapes on the pty: {frames_pty}")
ok = best >= min_keys and worst <= max_gap and frames_pty == 0
print(f"verdict: {'even' if ok else 'bunched-or-pty-frames'} (min_keys {min_keys}, max_gap {max_gap:.0f} ms, want 0 pty frames; exit {0 if ok else 4})")
sys.exit(0 if ok else 4)
