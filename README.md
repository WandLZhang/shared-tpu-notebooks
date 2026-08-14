# shared-tpu-notebooks

This repository gives several hundred students a Cloud TPU from a Jupyter notebook. You
do not buy one chip for each student.

Measured result: 300 students, 64 v5e chips, 12.4 minutes, 300 of 300 jobs completed,
$11.93.

Documentation in this repository uses ASD-STE100 Simplified Technical English.

---

## The problem

Colab Enterprise runtime templates supply GPU accelerators only. Vertex AI Workbench has
no TPU instance type. In Vertex AI, you attach TPUs to training jobs and to prediction
endpoints. You cannot attach a TPU to an interactive notebook VM.

The obvious alternative is one TPU notebook for each student. This does not scale. The
cause is a property of the platform. It is not a setting that you can change.

> GKE puts one pod on each TPU node. That pod uses all of the chips on the node. Two
> pods cannot share a TPU chip.

A TPU notebook therefore holds a full machine while the browser tab stays open. For 300
students, this is 300 chips. The chips stay allocated when nobody runs code.

## The design

Keep the notebook and the chip separate.

**Tier 1, the notebook.** Each student gets a JupyterLab pod with a CPU only. The pod
stays available. The student writes code in the pod. The student also debugs code and
reads the assignment in the pod. GKE bills this pod by its CPU request and its memory
request.

**Tier 2, the chip.** TPU work leaves the notebook as a Kubernetes Job.
[Kueue](https://kueue.sigs.k8s.io/) puts the job in a queue for a shared pool of chips.
`notebooks/submit_tpu.py` sends the job. It then waits, and it returns the output to the
notebook.

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

A student holds a chip only while the job runs. Other students continue to work.

GKE Autopilot builds the TPU node when a job needs one. Autopilot removes the node after
the job ends. Kueue controls the order of admission. Cohort borrowing lets an idle lab
section lend its chips to a busy lab section.

## Compare Vertex AI custom training first

Vertex AI custom training jobs run on TPU v5e and v6e. A CPU notebook sends a
`CustomJob`. Google operates the queue and the machines. The design is the same as this
repository, but you do not operate a cluster.

| item | this repository | Vertex custom jobs |
|---|---|---|
| second run of the same code | 15 s from a warm pool | a new container each time |
| fair share | Kueue cohorts, quota for each section | first come, on project quota |
| operations | you operate GKE and JupyterHub | none |
| isolation | you must add GKE Sandbox | one managed VM for each job |

Vertex removes five of the seven failures in this document. All five failures come from
JupyterHub on Autopilot.

Select the option by the type of assignment. Vertex is correct for batch homework. In
batch homework, a student writes code and reads the results later. This repository is
correct for iterative work. In iterative work, a student changes one line and runs the
code again.

Vertex AI *endpoints* are a different product. An endpoint serves a model that you
deploy. An endpoint does not run student code.

## Quick start

You must have a GCP project with billing. You must also have `gcloud`, `kubectl`, and
`helm`.

```bash
make preflight PROJECT=my-project     # read-only, no cost
make demo      PROJECT=my-project     # cluster, hub, and one TPU job (about 20 min)
```

`make demo` prints a port-forward command when it completes. Open the hub. Log in with
any username. Open `hw0_tpu_hello.ipynb`. Run the first cell.

```bash
make scale    PROJECT=my-project      # 100 students through 32 chips, with times
make teardown PROJECT=my-project      # then read the verification output
```

`make teardown` lists each cluster, TPU VM, and queued resource that remains. If the
three lists are empty, nothing bills.

## Speed

A warm pool contains a node that an earlier job left in place. A cold pool contains no
node. Autopilot must build one.

| condition | time from `run()` to output |
|---|---:|
| warm pool | **15 s** |
| cold pool | **2 min 37 s** |

Autopilot keeps an idle TPU node for several minutes. Most students therefore get a warm
pool during an active assignment period.

The first run of the day always uses a cold pool. Tell the students this. If you do not,
they report a fault. For the same reason, `submit_tpu.run()` prints each change of
state:

```
submitted tpu-ada-04ab51c3 to queue 'tpu'
  admitted after 5s in queue
```

A student who sees these two lines knows that the system operates correctly.

## Cost

The rates are for us-west4, on-demand, and are correct at the time of writing. Check the
current rates before you use them.

| item | rate | billed while |
|---|---:|---|
| v5e chip, Compute Engine | $1.20 for each chip-hour | a job runs |
| GKE Autopilot TPU v5e premium | $0.15 for each chip-hour | a job runs |
| Autopilot pod vCPU | $0.0501 for each vCPU-hour | a notebook stays open |
| Autopilot pod memory | $0.0055 for each GiB-hour | a notebook stays open |
| Cluster management fee | $0.10 for each hour | the cluster exists |

Two unit costs come from these rates:

- **One TPU job costs $0.040.** The 300 students used 8.84 chip-hours in total. This is
  106 seconds of chip time for each student.
- **One open notebook costs $0.289 for each hour.** This is the default profile of 4
  vCPU and 16 GiB.

### The notebook costs more than the chip

Calculate your own total. Two values control it. This repository measures neither value:

```
cost for each student = (runs x $0.040) + (hours the notebook stays open x $0.289)
```

A notebook that stays open for one hour costs the same as 7 TPU runs.

The idle culler is therefore the most important cost control in this repository. The
size of the chip pool is less important. `k8s/jupyterhub-values.yaml` sets the culler to
60 minutes. A student closes a laptop but does not log out. The pod stops one hour later.

Two changes decrease the largest cost:

1. Decrease the default profile to 2 vCPU and 8 GiB. This makes the notebook rate half
   as large.
2. Decrease the cull timeout. A shorter timeout starts more sessions again. Balance this
   against the 2 minute cold start.

Measure your own class before you calculate the cost of a term. Count the runs for each
student and the hours for each notebook from one assignment. Then use the equation above.

## Measured results

One run, 2026-08-13, `us-west4`. Four lab sections share one Kueue cohort.

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

Compare this with one dedicated chip for each student in the same session:

| method | chip-hours | cost |
|---|---:|---:|
| one chip for each student | 54.5 | $73.58 |
| queued | 8.84 | $11.93 |

The queue uses 6.2 times less chip time. It supports the same 300 students in the same
wall clock time. The ratio increases with the length of the assignment. The ratio follows
the part of the session in which a student runs code.

Notebook spawning fails in a different way. It is therefore measured separately. 50
concurrent logins produced 50 notebooks. The success rate was 100%, p50 was 137 s, and
p95 was 191 s.

To do these measurements again, use `scripts/04_scale_test.py` and
`scripts/06_hub_spawn_test.py`. Each value comes from a Kueue Workload condition
timestamp or from a Job status field.

## Seven failures that report the wrong cause

**1. `TPU_LITE_DEVICE_V5` is the wrong quota.** TPU v5e has two quota families. GKE and
the TPU API both use PodSlice quota (`ct5lp-`). They use it also for a single chip.
Device quota (`ct5l-`) is usually 0, and it does not apply. A request to increase the
wrong quota wastes a support cycle. `00_preflight.sh` prints both quotas.

**2. Kueue v1beta2 has a new name for `cohort`.** Use `cohortName`. The old name fails
with `unknown field "spec.cohort"`.

**3. Kueue flavors increase the capacity. They are not an overflow inside it.** A queue
with `v5e-ondemand: 8` and `v5e-flex: 8` holds 16 chips. It does not hold 8 chips with a
fallback. Four sections with this configuration make a pool of 64 chips when you intend
32. No error occurs. You buy two times the number of chips that you planned.
`02_create_cluster.sh` divides by the sections and also by the flavors.

**4. Autopilot rejects the JupyterHub `block-cloud-metadata` initContainer.** The
container is privileged and requests `NET_ADMIN`. The GKE Warden webhook returns HTTP
400. The pod does not start. The cause is visible only in the hub log.

Disable the container only if Workload Identity operates in `GKE_METADATA` mode. In that
mode, the metadata server already separates the pod from the node service account.
Confirm the mode first:

```bash
gcloud container clusters describe CLUSTER --format="value(workloadIdentityConfig.workloadPool)"
```

**5. Dataplane V2 applies NetworkPolicy after the Service DNAT.** JupyterHub denies
egress from student pods to private IP ranges. This denies access to the API server that
`submit_tpu.py` uses.

A rule that permits the `kubernetes` ClusterIP never matches. Policy runs after the
address becomes the private endpoint of the control plane. That endpoint is inside the
excluded range `10.0.0.0/8`. The result is a connection timeout to an address that the
policy appears to permit.

Permit the endpoint instead:

```bash
kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip}'
```

Do not set `privateIPs: true`. That setting permits student code to reach each other
student notebook.

**6. A `kubectl port-forward` connection stops the kernel and shows no error.** Jupyter
compares the browser `Origin` header with its own `Host` header. A port-forward makes the
two headers different. Each websocket returns HTTP 403. The kernel does not connect. A
cell stays at `[*]`, and the browser shows no error. The only record is `Blocking Cross
Origin API request` in the notebook pod log.

`jupyterhub-values.yaml` mounts a configuration file that relaxes this check. Delete that
file when you use an Ingress.

**7. A TPU node pool in `ERROR` with `RESOURCE_EXHAUSTED` is a pending request.** The
pool can recover one hour later. If you delete the pool, the wait starts again. This
repository uses Autopilot and does not have this condition. GKE Standard does have it.

## Changes to make before students use this

- **Authentication.** This repository supplies the dummy authenticator. Any username
  operates, and no password is necessary. Replace it with `GoogleOAuthenticator` for your
  domain.
- **Ingress.** The demonstration uses a port-forward. Use IAP-backed Ingress instead.
  This also removes failure 6.
- **Sandbox.** Student code is not trusted. Enable GKE Sandbox (gVisor) on student pods.
- **Namespaces.** This repository uses one namespace for each section. One namespace for
  each student gives better isolation.
- **A course image** that contains JAX and the Kubernetes client. This image replaces the
  `postStart` installation and decreases the cold start.
- **A reservation**, but only for a synchronous lab. In a synchronous lab, all students
  run code in the same minute. That condition needs one chip for each student. The queue
  design is for asynchronous homework.

## Layout

```
scripts/
  00_preflight.sh        quota, zones, accelerator types. Read-only.
  01_spray_v5e.sh        separate "no capacity now" from "not possible here"
  02_create_cluster.sh   Autopilot cluster, Kueue, section queues
  03_deploy_hub.sh       JupyterHub, student RBAC, API endpoint egress rule
  04_scale_test.py       N students through M chips, timed from Kueue conditions
  05_report.py           results table
  06_hub_spawn_test.py   concurrent notebook spawn times
  99_teardown.sh         delete all resources, then prove that nothing bills
k8s/
  kueue-tpu-queues.yaml  ResourceFlavors, section ClusterQueues, LocalQueues
  student-tpu-job.yaml   the TPU Job for one student
  jupyterhub-values.yaml three profiles and the Autopilot corrections
notebooks/
  hw0_tpu_hello.ipynb    an assignment on attention, the roofline, and flash attention
  submit_tpu.py          the helper that sends notebook code to a chip
```

## Notes on the chip

This repository uses v5e (`v5litepod-1`, one chip, `ct5lp-hightpu-1t`) for three reasons.
It has the lowest price of the current TPUs. Its single-chip topology is the correct unit
for one student. Its DWS Flex pools have less contention than newer generations. In the
measured run, 49 of the 80 TPU nodes came from flex-start at half of the on-demand price.

No part of the design needs v5e. To use a different generation, change the two
`nodeSelector` labels and the ResourceFlavor.

The JupyterHub TPU profile pattern is `extra_resource_limits` with `node_selector`. It
comes from [ai-on-gke](https://github.com/ai-on-gke/quick-start-guides). That template
uses TPU v4. One region supplies v4, and v4 has no DWS Flex path.

Apache 2.0.
