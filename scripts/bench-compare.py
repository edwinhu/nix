#!/usr/bin/env python3
"""Compare IMAP SEARCH on the candidate binary against a 1.3.14 reference binary.

INTERLEAVED, not against a recorded number. A stored baseline measures the
machine as much as it measures bun: the identical 1.3.14 artifact was observed
6% slower than its own recorded figures once the box got busy, which would fail
a strict comparison for a reason that has nothing to do with the runtime. Each
round therefore times the reference and the candidate back to back, so both see
the same load, and the verdict is min-vs-min across rounds.

Best-of-N rather than mean: the first search on a cold page cache is not the
number the pin protects. A real regression -- the kind this exists to catch was
~47x -- survives a minimum just as clearly.

A 10% tolerance, not equality. Interleaving cuts the error to ~1% but does not
remove it: two runs of the SAME 1.3.14 binary disagreed by 1.1%, so an equality
test decides on noise. 1.10x sits ~5x above that floor and ~30x below the
regression this guards (1.3.13 was ~47x slower), which is the whole usable band.

--record refreshes the reference binary's own figures for the report; the
comparison never reads them.
"""
import argparse, json, subprocess, sys, pathlib

TERMS = ["invoice", "virginia"]

ap = argparse.ArgumentParser()
for f in ("binary", "corpus", "account", "provider", "baseline"):
    ap.add_argument("--" + f, required=True)
ap.add_argument("--reference", help="1.3.14 binary to measure alongside the candidate")
ap.add_argument("--port", required=True)
ap.add_argument("--runs", type=int, default=7)
ap.add_argument("--tolerance", type=float, default=1.10,
                help="candidate may be at most this multiple of the reference")
ap.add_argument("--record", action="store_true")
a = ap.parse_args()

here = pathlib.Path(__file__).parent


def measure_once(binary: str, port: str) -> dict:
    proc = subprocess.run(
        [sys.executable, str(here / "search-bench.py"), binary, a.corpus,
         a.account, a.provider, port, *TERMS],
        capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit("bench run failed:\n" + proc.stderr[-3000:])
    return json.loads(proc.stdout)["results"]


def runtime_of(binary: str) -> str:
    return subprocess.run(
        ["grep", "-a", "-o", "-m1", "-E", r"Bun/[0-9]+\.[0-9]+\.[0-9]+", binary],
        capture_output=True, text=True).stdout.strip()


def fold(acc_best: dict, acc_hits: dict, results: dict) -> None:
    for term, r in results.items():
        if r["status"] != "OK":
            sys.exit(f"SEARCH {term} returned {r['status']}")
        acc_best[term] = min(acc_best.get(term, float("inf")), r["seconds"])
        acc_hits[term] = r["hits"]


best: dict[str, float] = {}
hits: dict[str, int] = {}
ref_best: dict[str, float] = {}
ref_hits: dict[str, int] = {}

for _ in range(a.runs):
    # Reference first, candidate second, every round: adjacent in time is the
    # only way both see the same machine.
    # Separate ports: the two listeners run back to back and a just-killed one
    # can still hold its bind.
    if a.reference:
        fold(ref_best, ref_hits, measure_once(a.reference, str(int(a.port) + 1)))
    fold(best, hits, measure_once(a.binary, a.port))

embedded = runtime_of(a.binary)
report = {"runtime": embedded, "runs": a.runs, "best_seconds": best, "hits": hits}

path = pathlib.Path(a.baseline)
if a.record:
    path.write_text(json.dumps(report, indent=2) + "\n")
    print("recorded baseline:", json.dumps(report))
    sys.exit(0)

if not a.reference:
    sys.exit("--reference is required: a stored baseline cannot separate a slow "
             "runtime from a busy machine")
ref_runtime = runtime_of(a.reference)
if not ref_runtime.startswith("Bun/1.3."):
    sys.exit(f"reference binary reports {ref_runtime}; expected a Bun/1.3.x artifact")

recorded = json.loads(path.read_text()) if path.exists() else None

failed = []
for term in TERMS:
    r, c = ref_best[term], best[term]
    ceiling = r * a.tolerance
    verdict = "ok" if c <= ceiling else "SLOWER"
    print(f"{term}: candidate {c:.4f}s vs reference {r:.4f}s "
          f"(ceiling {ceiling:.4f}s = {a.tolerance:g}x, {ref_runtime}) -- {verdict} "
          f"[{c / r:.2f}x]")
    if c > ceiling:
        failed.append(f"{term} {c:.4f}s > {ceiling:.4f}s ({c / r:.2f}x reference)")
    if hits[term] != ref_hits[term]:
        failed.append(f"{term} returned {hits[term]} hits, reference {ref_hits[term]}")
    if recorded and abs(r - recorded["best_seconds"][term]) / recorded["best_seconds"][term] > 0.25:
        print(f"  note: reference drifted {r:.4f}s vs {recorded['best_seconds'][term]:.4f}s "
              f"recorded on a quiet machine -- the box is loaded, which is why this "
              f"compares against a live reference rather than that number")

print(f"candidate {embedded} vs reference {ref_runtime}, best of {a.runs} "
      f"interleaved rounds, tolerance {a.tolerance:g}x")
if failed:
    sys.exit("assert-search-benchmark: " + "; ".join(failed))
print("assert-search-benchmark: ok")
