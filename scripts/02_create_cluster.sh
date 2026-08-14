#!/usr/bin/env bash
# Stand up the classroom substrate: Autopilot cluster, Kueue, section queues.
# Idempotent -- safe to re-run.
#
# This script uses Autopilot and not Standard. Autopilot builds one ct5lp-hightpu-1t
# node for each TPU pod. It reads the two nodeSelector labels to do this. It removes
# the node when the pod ends.
#
# Standard needs one node pool for each topology and the cluster autoscaler. A Standard
# node pool also requests all of its nodes in one atomic resize. If the zone cannot
# supply all of them at that moment, the resize fails with GCE_STOCKOUT. A queued
# request waits for capacity instead.
#
# Autopilot bills a TPU pod by the node. You pay for all 24 vCPU and 48 GiB while the
# pod runs. For this reason, student TPU work must be a short Job and not a notebook
# that stays open.
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
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

echo "==> resource flavors"
kubectl apply -f "$(dirname "$0")/../k8s/kueue-tpu-queues.yaml"

# Split the pool evenly across sections. Each section is guaranteed its share and
# borrows the rest from the cohort when the other sections are idle.
#
# Divide by the sections and also by the flavors. Kueue quota applies to each pair of
# flavor and resource. The flavors then add together into the capacity of the
# ClusterQueue.
#
# A second flavor does not make an overflow inside the budget of the first flavor. It
# adds a second budget.
#
# This error is silent. The first version of this script requested a pool of 32 chips.
# It used 4 sections, 8 chips, and 2 flavors, and it admitted 64 workloads together.
# No error occurs. You buy two times the chips that you planned.
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
