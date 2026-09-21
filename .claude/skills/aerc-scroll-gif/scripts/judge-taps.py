"""Key→frame latency from `strace -f -tt -e read,write` of aerc: for each tap timestamp (epoch
seconds, from the harness), the delay until aerc's next frame handoff — a kitty a=T escape on the
pty (standalone path) or a pane.graphics.stream header line on herdr's socket (herdr sink).
Usage: judge-taps.py <trace.txt> <lat_max_ms> <tap_epoch>... ; prints per-tap ms, median, verdict;
exit 0 fast (median ≤ lat_max), 1 sluggish (≤ 1.75×), 2 laggy, 3 unmeasured."""

import datetime as dt
import re
import sys

trace, lat_max = sys.argv[1], float(sys.argv[2])
taps = [float(x) for x in sys.argv[3:]]
head_re = re.compile(r"^(\d+) +(\d\d):(\d\d):(\d\d\.\d+) (.*)$")
frames = []
today = dt.datetime.fromtimestamp(taps[0]).date() if taps else dt.date.today()
with open(trace, errors="replace") as fh:
    for line in fh:
        h = head_re.match(line.rstrip("\n"))
        if not h:
            continue
        rest = h.group(5)
        if not (rest.startswith("write(") or "write resumed" in rest):
            continue
        if "a=T" not in rest and '\\"format\\":\\"rgba\\"' not in rest and "\"format\":\"rgba\"" not in rest and 'format\\":' not in rest:
            continue
        t = dt.datetime.combine(today, dt.time(int(h.group(2)), int(h.group(3)))).timestamp() + float(h.group(4))
        frames.append(t)
frames.sort()
if not frames:
    print("no frame writes in the trace")
    print("verdict: unmeasured (exit 3)")
    sys.exit(3)
lat = []
for tp in taps:
    nxt = next((f for f in frames if f >= tp), None)
    lat.append(round((nxt - tp) * 1000) if nxt is not None and nxt - tp < 1.4 else None)
print("latency ms per tap:", " ".join(str(x) if x is not None else "none" for x in lat))
good = sorted(x for x in lat if x is not None)
if not good:
    print("median key→frame ms: none")
    print("verdict: unmeasured (exit 3)")
    sys.exit(3)
med = good[len(good) // 2]
print(f"median key→frame ms: {med}")
if med <= lat_max:
    v, code = "fast", 0
elif med <= lat_max * 1.75:
    v, code = "sluggish", 1
else:
    v, code = "laggy", 2
print(f"verdict: {v} (median {med} ms vs {lat_max:.0f} ms; exit {code})")
sys.exit(code)
