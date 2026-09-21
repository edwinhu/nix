"""Key→pixel latency from changed frames in a recording of the test window.

Usage: judge-pixels.py <mp4> <recorder_start_epoch> <lat_max_ms> <tap_epoch>...
Prints per-tap ms, median, verdict; exit 0 fast (median <= lat_max), 1 sluggish (<= 1.75x),
2 laggy, 3 unmeasured. Same output and exit contract as judge-taps.py.
"""

import subprocess
import sys
from bisect import bisect_left
from decimal import Decimal


def escape(value, special):
    return "".join("\\" + char if char in special else char for char in value)


video, start, lat_max = sys.argv[1], Decimal(sys.argv[2]), float(sys.argv[3])
taps = [Decimal(x) - start for x in sys.argv[4:]]
# The filename passes through both the filtergraph and movie-option parsers.
filename = escape(escape(video, "\\': \t\r\n"), "\\'[],; \t\r\n")
try:
    probe = subprocess.run(
        [
            "ffprobe", "-v", "error", "-f", "lavfi",
            "-i", f"movie=filename={filename},select=gt(scene\\,0.0005)",
            "-show_entries", "frame=pts_time", "-of", "csv=p=0",
        ],
        check=True, capture_output=True, text=True,
    )
except (OSError, subprocess.CalledProcessError) as exc:
    print(exc.stderr if isinstance(exc, subprocess.CalledProcessError) else str(exc), file=sys.stderr)
    frames = []
else:
    frames = sorted(Decimal(line) for line in probe.stdout.splitlines() if line.strip())

lat = []
for tp in taps:
    index = bisect_left(frames, tp)
    nxt = frames[index] if index < len(frames) else None
    lat.append(round((nxt - tp) * 1000) if nxt is not None and nxt - tp < Decimal("1.4") else None)
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
