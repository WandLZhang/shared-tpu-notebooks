#!/usr/bin/env python3
"""Drive N students through a pool of M v5e chips and time every one of them.

This is the honesty check on the whole design. The claim being tested is that a class
of several hundred can share a few dozen chips, so what gets measured is queue wait,
not throughput on an empty cluster.

    python3 04_scale_test.py --students 300 --chips 32

Writes one JSON line per student to results/run-<stamp>.jsonl. 05_report.py turns that
into the table in README.md. Nothing here fabricates a number: every row comes from a
Kueue Workload object's own condition timestamps and the pod's own log.

Timings come from the Kueue Workload, not from wall-clock guesses:

    QuotaReserved   Kueue found a free chip for this student
    Admitted        the Job was unsuspended and the pod could be created
    Finished        the pod terminated

so queue_wait = QuotaReserved - created, and run_time = Finished - Admitted. The gap
between Admitted and the pod actually starting is node provisioning plus image pull,
which is reported separately because on a cold pool it dominates and it would be
misleading to call it queue time.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = pathlib.Path(__file__).resolve().parent
JOB_TEMPLATE = HERE.parent / "k8s" / "student-tpu-job.yaml"
RESULTS = HERE.parent / "results"


def kubectl(*args: str, check: bool = True) -> str:
    r = subprocess.run(
        ["kubectl", *args], capture_output=True, text=True, check=False
    )
    if check and r.returncode != 0:
        raise RuntimeError(f"kubectl {' '.join(args)} failed:\n{r.stderr}")
    return r.stdout


def parse_ts(s: str | None) -> float | None:
    if not s:
        return None
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=timezone.utc
    ).timestamp()


def submit(students: int, sections: list[str]) -> list[dict]:
    """Create every student Job up front. The stampede is the point of the test."""
    template = JOB_TEMPLATE.read_text()
    roster = []
    batch = []

    for i in range(students):
        sec = sections[i % len(sections)]
        name = f"student-{i:03d}"
        ns = f"class-sec-{sec}"
        manifest = (
            template.replace("__STUDENT__", name)
            .replace("__NAMESPACE__", ns)
            .replace("__QUEUE__", "tpu")
        )
        # Strip the leading comment block so the concatenated doc stays valid.
        manifest = manifest[manifest.index("apiVersion:") :]
        batch.append(manifest)
        roster.append({"student": name, "namespace": ns, "section": sec})

        # Apply in chunks; a single 300-doc apply is slow and hard to read when it
        # partially fails.
        if len(batch) == 25 or i == students - 1:
            doc = "\n---\n".join(batch)
            r = subprocess.run(
                ["kubectl", "apply", "-f", "-"],
                input=doc,
                capture_output=True,
                text=True,
            )
            if r.returncode != 0:
                print(r.stderr, file=sys.stderr)
            print(f"  submitted {i + 1}/{students}", flush=True)
            batch = []

    return roster


def collect(roster: list[dict], timeout: int) -> list[dict]:
    """Poll Kueue Workloads and Jobs until every student is done or time runs out."""
    by_name = {r["student"]: dict(r) for r in roster}
    t0 = time.time()
    concurrency = []  # (t, running) samples, for utilisation

    while time.time() - t0 < timeout:
        wl = json.loads(kubectl("get", "workloads", "-A", "-o", "json"))
        jobs = json.loads(kubectl("get", "jobs", "-A", "-o", "json"))

        job_state = {}
        for j in jobs["items"]:
            n = j["metadata"]["labels"].get("tpu-notebooks/student")
            if n:
                st = j.get("status", {})
                job_state[n] = {
                    "succeeded": st.get("succeeded", 0),
                    "failed": st.get("failed", 0),
                    "start": parse_ts(st.get("startTime")),
                    "completion": parse_ts(st.get("completionTime")),
                }

        running = 0
        for w in wl["items"]:
            owner = w["metadata"].get("ownerReferences", [{}])[0].get("name", "")
            if owner not in by_name:
                continue
            rec = by_name[owner]
            rec["created"] = parse_ts(w["metadata"].get("creationTimestamp"))
            for c in w.get("status", {}).get("conditions", []):
                if c["status"] != "True":
                    continue
                key = {
                    "QuotaReserved": "quota_reserved",
                    "Admitted": "admitted",
                    "Finished": "finished",
                }.get(c["type"])
                if key:
                    rec[key] = parse_ts(c.get("lastTransitionTime"))
            if rec.get("admitted") and not rec.get("finished"):
                running += 1
            rec.update(job_state.get(owner, {}))

        concurrency.append((time.time() - t0, running))
        done = sum(
            1 for r in by_name.values() if r.get("succeeded") or r.get("failed")
        )
        print(
            f"  t={time.time() - t0:6.0f}s  done={done}/{len(roster)}  running={running}",
            flush=True,
        )
        if done == len(roster):
            break
        time.sleep(15)

    for r in by_name.values():
        r["concurrency_samples"] = None
    out = list(by_name.values())
    out.append({"_meta": True, "concurrency": concurrency})
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--students", type=int, default=100)
    ap.add_argument("--chips", type=int, default=32)
    ap.add_argument("--sections", default="a b c d")
    ap.add_argument("--timeout", type=int, default=7200)
    args = ap.parse_args()

    sections = args.sections.split()
    RESULTS.mkdir(exist_ok=True)
    stamp = time.strftime("%m%d-%H%M%S")
    path = RESULTS / f"run-{stamp}.jsonl"

    print(f"==> {args.students} students, {args.chips} chips, sections {sections}")
    print(f"    results -> {path}")

    roster = submit(args.students, sections)
    print("==> all submitted; polling")
    rows = collect(roster, args.timeout)

    with path.open("w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")
    print(f"==> wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
