# shared-tpu-notebooks

Give several hundred students a Cloud TPU from a Jupyter notebook, without one chip for
each student.

In a test run, 300 students shared 64 v5e chips. The run took 12.4 minutes and cost
$11.93.

## How it works

GKE puts one pod on each TPU node, and that pod uses all of the chips on the node. Two
pods cannot share a TPU chip. A notebook with a chip attached therefore holds a full
machine while the browser tab stays open, and 300 students need 300 chips.

This repository keeps the notebook and the chip separate.

**The notebook.** Each student gets a JupyterLab pod with a CPU only. The student writes
code, debugs it, and reads the assignment in this pod.

**The chip.** TPU work leaves the notebook as a Kubernetes Job.
[Kueue](https://kueue.sigs.k8s.io/) puts the job in a queue for a shared pool of chips.
`notebooks/submit_tpu.py` sends the job, waits, and returns the output to the notebook.

```python
import submit_tpu

print(submit_tpu.run('''
import jax
print(jax.devices())
'''))
```

```
submitted tpu-ada-04ab51c3 to queue 'tpu'
  admitted after 5s in queue
  Succeeded after 15s total
devices: [TpuDevice(id=0, process_index=0, coords=(0,0,0), core_on_chip=0)]
```

A student holds a chip only while the job runs.

GKE Autopilot builds a TPU node when a job needs one, and removes the node after the job
ends. Kueue controls the order of admission. Four lab sections share one cohort, so an
idle section lends its chips to a busy section.

## Quick start

You need a GCP project with billing, `gcloud`, `kubectl`, and `helm`.

```bash
make preflight PROJECT=my-project     # read-only, no cost
make demo      PROJECT=my-project     # cluster, hub, and one TPU job (about 20 min)
```

Then put the hub behind HTTPS and Google sign-in. Run this once per cluster:

```bash
make iap PROJECT=my-project           # prints the URL when the certificate is ready
```

Open that URL, sign in with a Google account in your organization, open
`hw0_tpu_hello.ipynb`, and run the first cell.

```bash
make warm-on  PROJECT=my-project      # hold 1 chip ready so the first run is quick
make scale    PROJECT=my-project      # 100 students through 32 chips, with times
make warm-off PROJECT=my-project      # warm chips bill continuously
make teardown PROJECT=my-project      # then read the verification output
```

`make teardown` lists each cluster, TPU VM, and queued resource that remains. If the
three lists are empty, nothing bills.

## Speed

A warm pool contains a TPU node that an earlier job left in place. A cold pool contains
no node, so Autopilot must build one.

| condition | pod scheduled | job finished |
|---|---:|---:|
| warm pool on | **+0 s** | **21 s** |
| cold, no node | 2 to 4 min | 157 to 261 s |

In a cold run the node build takes most of the time. The work itself is about 45 seconds.

Do not rely on a node being left warm. Autopilot removes an idle TPU node about two
minutes after a job ends, and `submit_tpu.run()` deletes the Job as soon as it returns,
which empties the node right away. Scale-to-zero works against you here.

`make warm-on` holds placeholder pods on TPU nodes instead. A student job outranks a
placeholder, so the scheduler evicts one and the student lands on a node that already
runs. The Deployment then warms a replacement node. See `k8s/tpu-warm-pool.yaml` for the
priority value and the cost.

Each run starts a new container, so about 10 seconds of JAX and libtpu initialization
applies to every run. No state carries between runs.

## Cost

Rates are for us-west4, on-demand. Check the current rates before you use them.

| item | rate | billed while |
|---|---:|---|
| v5e chip, Compute Engine | $1.20 for each chip-hour | a job runs |
| GKE Autopilot TPU v5e premium | $0.15 for each chip-hour | a job runs |
| Autopilot pod vCPU | $0.0501 for each vCPU-hour | a notebook stays open |
| Autopilot pod memory | $0.0055 for each GiB-hour | a notebook stays open |
| Cluster management fee | $0.10 for each hour | the cluster exists |

Two unit costs come from these rates:

- **One TPU job costs $0.040.** This is the measured mean of 106 seconds of chip time.
  A short debug run of about 15 seconds costs $0.006.
- **One open notebook costs $0.289 for each hour** at the default 4 vCPU and 16 GiB.

### One hour with 100 students

| runs for each student | chips needed | TPU | notebooks and cluster | total |
|---:|---:|---:|---:|---:|
| 2 | 6 | $8 | $29 | **$37** |
| 5 | 15 | $20 | $29 | **$49** |
| 10 | 29 | $40 | $29 | **$69** |
| 20 | 59 | $80 | $29 | **$109** |

### Where the cost goes

A notebook that stays open for one hour costs the same as 7 TPU runs. At 2 runs for each
student, the notebooks are 78% of the total.

The idle culler therefore controls more of the bill than the size of the chip pool.
`k8s/jupyterhub-values.yaml` sets it to 60 minutes.

Two changes reduce the notebook cost:

1. Decrease the default profile to 2 vCPU and 8 GiB. This makes the notebook rate half as
   large, and the typical hour above costs about $35.
2. Decrease the cull timeout. A shorter timeout starts more sessions again, so balance it
   against the 2 minute cold start.

Calculate your own total with this equation. Measure both inputs from one assignment,
because this repository measures neither:

```
cost for each student = (runs x $0.040) + (hours the notebook stays open x $0.289)
```

## Capacity

| item | limit | source |
|---|---:|---|
| notebooks open at the same time | 370 | regional `CPUS` quota of 1500, at 4 vCPU each |
| TPU chips at the same time | 512 | `TPU_LITE_PODSLICE_V5` quota for each region |
| TPU chips at the same time, Spot | 1536 | `PREEMPTIBLE_TPU_LITE_PODSLICE_V5` |

Both quotas are project defaults. Raise either with a quota request.

Concurrent chips are not the same as class size. The 300 students in the measured run
used 64 chips, because each student held a chip only while a job ran.

## Configuration

All of these are environment overrides on the scripts, or values in the Makefile.

| variable | default | effect |
|---|---|---|
| `PROJECT` | none, required | GCP project |
| `REGION` | `us-west4` | cluster region |
| `POOL_CHIPS` | 32 | total chips across all sections |
| `SECTIONS` | `a b c d` | one namespace and one queue for each section |
| `CLUSTER` | `tpu-notebooks` | cluster name |

`02_create_cluster.sh` divides `POOL_CHIPS` by the number of sections and by the number
of flavors. Kueue quota applies to each pair of flavor and resource, and the flavors add
together into the capacity of the queue.

JupyterHub supplies three profiles in `k8s/jupyterhub-values.yaml`:

| profile | resources | who |
|---|---|---|
| Course default, CPU notebook | 4 vCPU, 16 GiB | students |
| Large CPU notebook | 8 vCPU, 32 GiB | students |
| Pinned TPU v5e notebook | 1 chip attached | staff only |

The pinned profile attaches a chip for the life of the notebook, at $1.35 for each hour.
`allowed_groups` limits it to staff.

## Changes to make before students use this

- **A real domain.** `make iap` uses `nip.io`, which maps the load balancer address to a
  hostname without a DNS zone. That is enough to prove the setup. For a course, register a
  domain, point an A record at the reserved address, and run
  `DOMAIN=jupyter.your-university.edu make iap`.
- **A group on the IAP binding.** `make iap` grants access to the account that runs it.
  Grant a group instead, and IAP then supplies group claims, which makes `allowed_groups`
  on the staff profile enforce. Without groups that profile gate does nothing and any user
  can select the pinned-chip profile.
- **Cross-origin.** Delete the `jupyter_server_config.py` entry from
  `k8s/jupyterhub-values.yaml` once you no longer use a port-forward. It relaxes the
  cross-origin check, and behind an Ingress the check works correctly on its own.
- **Sandbox.** Student code is not trusted. Enable GKE Sandbox (gVisor) on student pods.
- **Namespaces.** This repository uses one namespace for each section. One namespace for
  each student gives better isolation.
- **A course image** that contains JAX and the Kubernetes client. This image replaces the
  `postStart` installation and decreases the cold start.
- **A reservation**, but only for a synchronous lab in which all students run code in the
  same minute. That condition needs one chip for each student.

## Measured results

One run, `us-west4`. Four lab sections share one Kueue cohort.

| metric | value |
|---|---:|
| students | 300 |
| completed | 300 |
| failed | 0 |
| maximum concurrent chips | 64 |
| wall clock, first submit to last completion | 12.4 min |
| queue wait p50 / p95 | 270 s / 487 s |
| node build and image pull p50 / p95 | 23 s / 74 s |
| job run time p50 | 52 s |
| chip-hours used | 8.84 |

One dedicated chip for each of the 300 students would use 54.5 chip-hours and cost
$73.58 over the same period.

Notebook spawning is measured separately. 50 concurrent logins produced 50 notebooks,
with p50 137 s and p95 191 s.

To repeat both measurements, use `scripts/04_scale_test.py` and
`scripts/06_hub_spawn_test.py`. Each value comes from a Kueue Workload condition
timestamp or from a Job status field.

## Layout

```
scripts/
  00_preflight.sh        quota, zones, accelerator types. Read-only.
  01_spray_v5e.sh        test which zones can supply a chip
  02_create_cluster.sh   Autopilot cluster, Kueue, section queues
  03_deploy_hub.sh       JupyterHub, student RBAC, API endpoint egress rule
  04_scale_test.py       N students through M chips, timed from Kueue conditions
  05_report.py           results table
  06_hub_spawn_test.py   concurrent notebook spawn times
  07_warm_pool.sh        hold warm TPU nodes: on [N] | off | status
  08_setup_iap.sh        HTTPS and Google sign-in, once for each cluster
  99_teardown.sh         delete all resources, then prove that nothing bills
k8s/
  kueue-tpu-queues.yaml  ResourceFlavors, section ClusterQueues, LocalQueues
  student-tpu-job.yaml   the TPU Job for one student
  jupyterhub-values.yaml three profiles and the Autopilot settings
  ingress-iap.yaml       BackendConfig, ManagedCertificate, and Ingress
  tpu-warm-pool.yaml     PriorityClass and the placeholder Deployment
notebooks/
  hw0_tpu_hello.ipynb    an assignment on attention, the roofline, and flash attention
  submit_tpu.py          the helper that sends notebook code to a chip
```

## Using a different TPU generation

This repository uses v5e (`v5litepod-1`, one chip, `ct5lp-hightpu-1t`). To use another
generation, change the two `nodeSelector` labels in `k8s/student-tpu-job.yaml` and
`notebooks/submit_tpu.py`, and the matching `nodeLabels` in `k8s/kueue-tpu-queues.yaml`.
Confirm that your project holds quota for that generation with `00_preflight.sh`.

Apache 2.0.
