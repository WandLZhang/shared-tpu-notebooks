"""Run code on a TPU chip from a CPU notebook.

This is the piece that makes the classroom affordable. The student's notebook has no
accelerator. When they call run(), this submits a Kubernetes Job that Kueue queues
against the shared v5e pool, waits for a chip, runs their code on it, and streams the
output back. The chip is held for the seconds the job runs, not for the hours the
notebook is open.

    import submit_tpu
    submit_tpu.run('''
        import jax, jax.numpy as jnp
        print(jax.devices())
        print(jnp.ones((4, 4)) @ jnp.ones((4, 4)))
    ''')

The notebook does not get its own TPU because GKE schedules one pod per TPU node, and
that pod uses every chip on the node. Two students cannot share a v5e chip. An attached
chip therefore holds a full node while the student reads the assignment. For 300
students that is 300 nodes. A queue turns the same class into a 32-chip pool.
"""

from __future__ import annotations

import os
import time
import uuid

from kubernetes import client, config
from kubernetes.client.exceptions import ApiException

TPU_IMAGE = os.environ.get(
    "TPU_IMAGE", "us-docker.pkg.dev/cloud-tpu-images/jax-ai-image/tpu:latest"
)
QUEUE = os.environ.get("KUEUE_LOCAL_QUEUE", "tpu")


class JobInterrupted(RuntimeError):
    """The job went away before it could run. Nothing executed; re-running is safe."""


def _delete(batch: "client.BatchV1Api", name: str, ns: str) -> None:
    """Delete a Job, tolerating the case where it is already gone."""
    try:
        batch.delete_namespaced_job(name, ns, propagation_policy="Background")
    except ApiException as e:
        if e.status != 404:
            raise


def _namespace() -> str:
    """The namespace this notebook pod runs in."""
    path = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"
    if os.path.exists(path):
        with open(path) as fh:
            return fh.read().strip()
    return os.environ.get("POD_NAMESPACE", "default")


def _load() -> None:
    try:
        config.load_incluster_config()
    except config.ConfigException:
        config.load_kube_config()


def run(code: str, timeout: int = 1800, keep: bool = False) -> str:
    """Run `code` on one v5e chip. Blocks until it finishes. Returns stdout.

    timeout covers the whole wait: queue time plus node provisioning plus the run.
    A cold chip can take several minutes to arrive, which is normal and is why the
    function prints its state transitions rather than sitting silent.
    """
    _load()
    ns = _namespace()
    name = f"tpu-{os.environ.get('JUPYTERHUB_USER', 'anon')}-{uuid.uuid4().hex[:8]}"
    name = name.replace("_", "-").lower()[:63]

    batch = client.BatchV1Api()
    core = client.CoreV1Api()

    job = client.V1Job(
        metadata=client.V1ObjectMeta(
            name=name,
            namespace=ns,
            # This label sends the job to Kueue. Without it the pod schedules at once,
            # and 300 students overload the pool together.
            labels={"kueue.x-k8s.io/queue-name": QUEUE},
        ),
        spec=client.V1JobSpec(
            # Kueue owns admission; it unsuspends when a chip is free.
            suspend=True,
            backoff_limit=0,
            ttl_seconds_after_finished=None if keep else 600,
            template=client.V1PodTemplateSpec(
                spec=client.V1PodSpec(
                    restart_policy="Never",
                    # Fungible: yields to notebooks, Kueue re-queues it.
                    priority_class_name="student-tpu-job",
                    node_selector={
                        "cloud.google.com/gke-tpu-accelerator": "tpu-v5-lite-podslice",
                        "cloud.google.com/gke-tpu-topology": "1x1",
                    },
                    tolerations=[
                        client.V1Toleration(
                            key="google.com/tpu", operator="Exists", effect="NoSchedule"
                        )
                    ],
                    containers=[
                        client.V1Container(
                            name="hw",
                            image=TPU_IMAGE,
                            command=["python3", "-c", code],
                            # Fail loudly instead of silently falling back to CPU. A
                            # CPU fallback produces plausible numbers that are wrong.
                            env=[client.V1EnvVar(name="JAX_PLATFORMS", value="tpu")],
                            resources=client.V1ResourceRequirements(
                                limits={"google.com/tpu": "1"},
                                requests={"google.com/tpu": "1"},
                            ),
                        )
                    ],
                )
            ),
        ),
    )

    batch.create_namespaced_job(ns, job)
    print(f"submitted {name} to queue '{QUEUE}'", flush=True)

    t0 = time.time()
    admitted_at = None

    try:
        while time.time() - t0 < timeout:
            try:
                j = batch.read_namespaced_job(name, ns)
            except ApiException as e:
                # Someone deleted the job while we were waiting: a TA clearing a stuck
                # queue, a TTL sweep, a kubectl delete. That is an interruption, not a
                # failure of the student's code, so say so plainly instead of letting a
                # raw 404 traceback end the cell.
                if e.status == 404:
                    raise JobInterrupted(
                        f"{name} was deleted while waiting for a chip. Nothing ran. "
                        f"Re-run the cell to submit again."
                    ) from None
                raise

            if admitted_at is None and not j.spec.suspend:
                admitted_at = time.time()
                print(f"  admitted after {admitted_at - t0:.0f}s in queue", flush=True)

            pods = core.list_namespaced_pod(
                ns, label_selector=f"job-name={name}"
            ).items
            if pods:
                phase = pods[0].status.phase
                if phase in ("Succeeded", "Failed"):
                    out = core.read_namespaced_pod_log(pods[0].metadata.name, ns)
                    print(f"  {phase} after {time.time() - t0:.0f}s total", flush=True)
                    if not keep:
                        _delete(batch, name, ns)
                    if phase == "Failed":
                        raise RuntimeError(f"job failed:\n{out}")
                    return out
            time.sleep(5)

    except KeyboardInterrupt:
        # Ctrl-C stops the poller, not the job. Without this the Job keeps its place in
        # the queue and can still take a chip with nobody watching for the result.
        print(f"  interrupted; deleting {name}", flush=True)
        _delete(batch, name, ns)
        raise

    _delete(batch, name, ns)
    raise TimeoutError(
        f"{name} did not finish within {timeout}s. The pool is busy or the zone is "
        f"out of v5e. Check: kubectl get workloads -n {ns}"
    )
