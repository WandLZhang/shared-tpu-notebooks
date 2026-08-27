#!/usr/bin/env bash
# Stand up the classroom substrate: Autopilot cluster, Kueue, section queues.
# Idempotent -- safe to re-run.
#
# Autopilot, not Standard, on purpose. Autopilot provisions a ct5lp-hightpu-1t node
# per TPU pod from the two nodeSelector labels and scales back to zero when the pod
# ends. Standard would need a node pool per topology plus the cluster autoscaler, and
# ai-infra-demo-2026-05/capacity/README.md:127 records why that is worse on tight
# supply: a Standard node pool asks Compute for all its nodes in ONE atomic resize
# and hard-fails on GCE_STOCKOUT, while the queued path waits for a window.
#
# The trade Autopilot makes is billing. A TPU pod is node-billed, so you pay for the
# whole 24 vCPU / 48 GiB node for as long as the pod lives. That is why student TPU
# work is a short Job and not a long-lived notebook.
set -euo pipefail

PROJECT="${PROJECT:-${PROJECT:?set PROJECT to your GCP project id}}"
REGION="${REGION:-us-west4}"
CLUSTER="${CLUSTER:-tpu-notebooks}"
KUEUE_VERSION="${KUEUE_VERSION:-v0.19.1}"
POOL_CHIPS="${POOL_CHIPS:-32}"
SECTIONS="${SECTIONS:-a b c d}"

echo "==> cluster ${CLUSTER} in ${REGION}"
if ! gcloud container clusters describe "${CLUSTER}" --region="${REGION}" \
       --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud container clusters create-auto "${CLUSTER}" \
    --project="${PROJECT}" --region="${REGION}" \
    --release-channel=rapid \
    --network=default --subnetwork=default
else
  echo "    exists"
fi

gcloud container clusters get-credentials "${CLUSTER}" \
  --region="${REGION}" --project="${PROJECT}"

# Guard against runaway log ingestion costs ($0.50/GiB). A student writing
# `while True: print("hello")` can silently ingest terabytes of logs overnight.
# This exclusion filter drops container stdout/stderr from student namespaces
# before it reaches Cloud Logging billing. Logs from kube-system, the hub pod,
# and other infrastructure namespaces are preserved.
echo "==> log exclusion filter for student namespaces"
if ! gcloud logging sinks describe "_Default" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "    warning: could not verify default sink; skipping log exclusion"
else
  gcloud logging sinks update "_Default" \
    --project="${PROJECT}" \
    --add-exclusion="name=student-notebook-noise,filter=resource.labels.namespace_name=~\"^class-sec-\" AND resource.labels.pod_name=~\"^jupyter-\"" \
    2>/dev/null || echo "    exclusion already exists or could not be created"
fi

echo "==> Kueue ${KUEUE_VERSION}"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml"

echo "    waiting for the Kueue controller to be available..."
kubectl -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=600s

# The webhook takes a few seconds past Available before it will accept CRs. Applying
# a ClusterQueue too early fails with 'no endpoints available for service'.
echo "    waiting for the Kueue webhook to answer..."
for i in $(seq 1 60); do
  kubectl get clusterqueue >/dev/null 2>&1 && break
  sleep 5
done

# Priority classes must exist before the hub is installed. 03_deploy_hub.sh references
# jupyterhub-core and student-notebook, and Kubernetes rejects a pod whose
# priorityClassName does not resolve. Applying these by hand during development and
# forgetting to wire them in here is what broke `make hub` for a user.
echo "==> priority classes"
kubectl apply -f "$(dirname "$0")/../k8s/priority-classes.yaml"

echo "==> resource flavors"
kubectl apply -f "$(dirname "$0")/../k8s/kueue-tpu-queues.yaml"

# Split the pool evenly across sections. Each section is guaranteed its share and
# borrows the rest from the cohort when the other sections are idle.
#
# Divide by sections AND by flavors. Kueue quota is per (flavor, resource) and the
# flavors SUM into the ClusterQueue's capacity -- listing a second flavor does not
# create an overflow lane inside the first one's budget, it adds a second budget.
# Getting this wrong is silent: the first run of this script asked for a 32-chip pool
# with 4 sections x 8 chips x 2 flavors and admitted 64 workloads at once. Nothing
# errors, you simply buy twice the chips you planned for.
NSEC=$(echo "${SECTIONS}" | wc -w)
NFLAVORS=2
PER=$(( POOL_CHIPS / NSEC / NFLAVORS ))
echo "==> ${NSEC} sections x ${NFLAVORS} flavors x ${PER} chips = ${POOL_CHIPS} in the cohort"

for S in ${SECTIONS}; do
  kubectl apply -f - <<EOF
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: section-${S}
spec:
  cohortName: classroom
  namespaceSelector: {}
  queueingStrategy: BestEffortFIFO
  resourceGroups:
    - coveredResources: ["google.com/tpu"]
      flavors:
        - name: v5e-ondemand
          resources:
            - name: "google.com/tpu"
              nominalQuota: ${PER}
        - name: v5e-flex
          resources:
            - name: "google.com/tpu"
              nominalQuota: ${PER}
---
apiVersion: v1
kind: Namespace
metadata:
  name: class-sec-${S}
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: section-quota
  namespace: class-sec-${S}
spec:
  hard:
    count/jobs.batch: "250"
    count/pods: "500"
    count/persistentvolumeclaims: "300"
    # Cap total provisioned storage per section. Without this, a single rogue
    # PVC request could create a TB-scale persistent disk bill.
    requests.storage: "500Gi"
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: LocalQueue
metadata:
  name: tpu
  namespace: class-sec-${S}
spec:
  clusterQueue: section-${S}
EOF
done

echo
echo "==> state"
kubectl get clusterqueue
kubectl get localqueue -A
echo
echo "Pool: ${POOL_CHIPS} chips. An idle section lends its share to the other sections."
echo "A section that submits work takes its share back."
