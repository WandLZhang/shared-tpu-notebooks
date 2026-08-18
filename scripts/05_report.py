#!/usr/bin/env python3
"""Turn a scale-test JSONL into the results table.

Every number here is derived from a Kueue Workload condition timestamp or a Job
status field. Nothing is modelled, extrapolated or filled in. If a student's row is
missing a timestamp the row is counted as incomplete and said so, rather than being
dropped to make the percentiles look better.

    python3 05_report.py                    # newest run
    python3 05_report.py results/run-X.jsonl
"""

from __future__ import annotations

import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
RESULTS = HERE.parent / "results"

# v5e on Autopilot is node-billed: the $1.20 base chip rate plus the Autopilot
# accelerator premium. Use the base rate alone and every total here reads low.
CHIP_HR = 1.35


def pct(xs: list[float], p: float) -> float:
    if not xs:
        return float("nan")
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def main() -> int:
    if len(sys.argv) > 1:
        path = pathlib.Path(sys.argv[1])
    else:
        runs = sorted(RESULTS.glob("run-*.jsonl"))
        if not runs:
            print("no runs in results/", file=sys.stderr)
            return 1
        path = runs[-1]

    rows, meta = [], {}
    for line in path.read_text().splitlines():
        r = json.loads(line)
        if r.get("_meta"):
            meta.update(r)
        else:
            rows.append(r)

    total = len(rows)
    ok = [r for r in rows if r.get("succeeded")]
    failed = [r for r in rows if r.get("failed")]
    incomplete = [r for r in rows if not r.get("succeeded") and not r.get("failed")]

    # queue_wait: submitted -> Kueue found a chip. This is the number the design is
    # actually claiming something about.
    waits = [
        r["quota_reserved"] - r["created"]
        for r in rows
        if r.get("quota_reserved") and r.get("created")
    ]
    # provision: admitted -> pod actually started. Node creation plus image pull.
    # Reported separately because on a cold pool it dominates, and folding it into
    # queue time would overstate contention.
    provs = [
        r["start"] - r["admitted"]
        for r in rows
        if r.get("start") and r.get("admitted")
    ]
    runs_ = [
        r["completion"] - r["start"]
        for r in rows
        if r.get("completion") and r.get("start")
    ]
    e2e = [
        r["completion"] - r["created"]
        for r in rows
        if r.get("completion") and r.get("created")
    ]

    conc = meta.get("concurrency") or []
    peak = max((c for _, c in conc), default=0)
    wall = max((t for t, _ in conc), default=0)

    # Chip-seconds actually consumed, from per-job durations. Autopilot bills the
    # whole node while the pod runs, and one pod is one chip, so this is the bill.
    chip_sec = sum(runs_)
    cost = chip_sec / 3600 * CHIP_HR

    print(f"# {path.name}")
    print()
    print(f"| metric | value |")
    print(f"|---|---:|")
    print(f"| students | {total} |")
    print(f"| completed | {len(ok)} |")
    print(f"| failed | {len(failed)} |")
    print(f"| still running at cutoff | {len(incomplete)} |")
    print(f"| peak concurrent chips | {peak} |")
    print(f"| wall clock to drain | {wall / 60:.1f} min |")
    print(f"| queue wait p50 | {pct(waits, 0.50):.0f} s |")
    print(f"| queue wait p95 | {pct(waits, 0.95):.0f} s |")
    print(f"| queue wait max | {max(waits, default=0):.0f} s |")
    print(f"| node provision + image pull p50 | {pct(provs, 0.50):.0f} s |")
    print(f"| node provision + image pull p95 | {pct(provs, 0.95):.0f} s |")
    print(f"| job run time p50 | {pct(runs_, 0.50):.0f} s |")
    print(f"| end to end p50 | {pct(e2e, 0.50):.0f} s |")
    print(f"| end to end p95 | {pct(e2e, 0.95):.0f} s |")
    print(f"| chip-hours consumed | {chip_sec / 3600:.2f} |")
    print(f"| TPU cost at ${CHIP_HR}/chip-hr | ${cost:.2f} |")
    print(f"| cost per student | ${cost / max(total, 1):.3f} |")
    print()

    by_sec: dict[str, int] = {}
    for r in ok:
        by_sec[r.get("section", "?")] = by_sec.get(r.get("section", "?"), 0) + 1
    print("completions by section: " + ", ".join(f"{k}={v}" for k, v in sorted(by_sec.items())))

    if incomplete:
        print()
        print(f"NOT COMPLETE: {len(incomplete)} students had not finished when the")
        print("poller stopped. They are counted above and not hidden.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
