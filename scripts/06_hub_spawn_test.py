#!/usr/bin/env python3
"""Spawn N JupyterHub notebook servers at once and time every spawn.

The 300-student queue test measures the chips. This measures the hub: can it take a
lecture hall logging in at the same minute, and how long does the slowest student wait
for a notebook? Those are different failure modes and neither one covers the other.

Runs against the hub's own REST API from inside the hub pod, so it needs no external
LoadBalancer -- which matters here because an org policy blocks the public one.

    python3 06_hub_spawn_test.py --users 50

Every number is a real pod reaching Running, read from the Kubernetes API.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time

NS = os.environ.get("NAMESPACE", "class-sec-a")
PROFILE = "course-default-cpu-notebook"


def sh(*args: str) -> str:
    r = subprocess.run(args, capture_output=True, text=True)
    return r.stdout.strip()


def hub_pod() -> str:
    return sh(
        "kubectl", "-n", NS, "get", "pod", "-l", "component=hub",
        "-o", "jsonpath={.items[0].metadata.name}",
    )


def api(hub: str, token: str, method: str, path: str, body: str | None = None) -> str:
    cmd = [
        "kubectl", "-n", NS, "exec", hub, "--",
        "curl", "-s", "-X", method,
        "-H", f"Authorization: token {token}",
        "-H", "Content-Type: application/json",
    ]
    if body:
        cmd += ["-d", body]
    cmd.append(f"http://127.0.0.1:8081/hub/api{path}")
    return sh(*cmd)


def pct(xs: list[float], p: float) -> float:
    if not xs:
        return float("nan")
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--users", type=int, default=50)
    ap.add_argument("--timeout", type=int, default=1800)
    args = ap.parse_args()

    hub = hub_pod()
    token = sh("kubectl", "-n", NS, "exec", hub, "--", "jupyterhub", "token", "professor")
    token = token.splitlines()[-1].strip()
    print(f"hub={hub}")

    users = [f"hubtest-{i:03d}" for i in range(args.users)]

    print(f"==> creating {len(users)} users")
    for u in users:
        api(hub, token, "POST", f"/users/{u}")

    print("==> spawning all at once")
    t0 = time.time()
    procs = []
    for u in users:
        procs.append(
            subprocess.Popen(
                [
                    "kubectl", "-n", NS, "exec", hub, "--",
                    "curl", "-s", "-o", "/dev/null", "-X", "POST",
                    "-H", f"Authorization: token {token}",
                    "-H", "Content-Type: application/json",
                    "-d", json.dumps({"profile": PROFILE}),
                    f"http://127.0.0.1:8081/hub/api/users/{u}/server",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        )
    for p in procs:
        p.wait()
    print(f"    all spawn requests issued in {time.time() - t0:.0f}s")

    ready: dict[str, float] = {}
    while time.time() - t0 < args.timeout:
        out = sh(
            "kubectl", "-n", NS, "get", "pods",
            "-l", "component=singleuser-server",
            "-o", "json",
        )
        try:
            items = json.loads(out)["items"]
        except Exception:
            items = []
        want = set(users)
        for p in items:
            name = p["metadata"]["name"]
            u = name.replace("jupyter-", "")
            # Count only this run's users. The label selector also matches any
            # notebook already running in the namespace, which is how a 50-user run
            # first reported 51/50 ready.
            if u not in want:
                continue
            if u not in ready and p["status"].get("phase") == "Running":
                conds = {c["type"]: c for c in p["status"].get("conditions", [])}
                if conds.get("Ready", {}).get("status") == "True":
                    ready[u] = time.time() - t0
        print(f"  t={time.time() - t0:5.0f}s  ready={len(ready)}/{len(users)}", flush=True)
        if len(ready) >= len(users):
            break
        time.sleep(10)

    lat = list(ready.values())
    print()
    print(f"| metric | value |")
    print(f"|---|---:|")
    print(f"| notebooks requested | {len(users)} |")
    print(f"| notebooks Ready | {len(ready)} |")
    print(f"| spawn success rate | {100 * len(ready) / len(users):.0f}% |")
    print(f"| spawn latency p50 | {pct(lat, 0.50):.0f} s |")
    print(f"| spawn latency p95 | {pct(lat, 0.95):.0f} s |")
    print(f"| spawn latency max | {max(lat, default=0):.0f} s |")

    print()
    print("==> cleaning up")
    for u in users:
        api(hub, token, "DELETE", f"/users/{u}/server")
    for u in users:
        api(hub, token, "DELETE", f"/users/{u}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
