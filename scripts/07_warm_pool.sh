#!/usr/bin/env bash
# Turn warm TPU nodes on and off.
#
#   bash 07_warm_pool.sh on [N]   hold N chips warm (default 4)
#   bash 07_warm_pool.sh off      release them
#   bash 07_warm_pool.sh status   what's warm and what it's costing
#
# Warm chips bill continuously. Leaving this on overnight is the expensive mistake, so
# `on` always prints the burn rate and `status` always prints the running total.
set -euo pipefail

PROJECT="${PROJECT:-${PROJECT:?set PROJECT to your GCP project id}}"
REGION="${REGION:-us-west4}"
CLUSTER="${CLUSTER:-tpu-notebooks}"
NAMESPACE="${NAMESPACE:-class-sec-a}"
CHIP_HR="${CHIP_HR:-1.20}"          # v5e on-demand, us-west4
DEFAULT_REPLICAS="${DEFAULT_REPLICAS:-4}"

# Pin the context. The default kubectl context in this workspace drifted to an unrelated
# cluster three times in one session, and a drifted context silently targets the wrong
# place.
CTX="gke_${PROJECT}_${REGION}_${CLUSTER}"
if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "${CTX}"; then
  gcloud container clusters get-credentials "${CLUSTER}" \
    --region="${REGION}" --project="${PROJECT}" >/dev/null 2>&1
fi
K=(kubectl --context="${CTX}" -n "${NAMESPACE}")

ACTION="${1:-status}"

warm_nodes() {
  kubectl --context="${CTX}" get nodes \
    -l cloud.google.com/gke-tpu-accelerator=tpu-v5-lite-podslice \
    --no-headers 2>/dev/null | wc -l | tr -d ' '
}

case "${ACTION}" in
  on)
    N="${2:-${DEFAULT_REPLICAS}}"
    # Apply the manifest first so a fresh cluster works without running anything else.
    sed "s|__NAMESPACE__|${NAMESPACE}|g" "$(dirname "$0")/../k8s/tpu-warm-pool.yaml" \
      | kubectl --context="${CTX}" apply -f - >/dev/null
    "${K[@]}" scale deployment/tpu-warm-pool --replicas="${N}" >/dev/null
    COST=$(awk -v n="${N}" -v c="${CHIP_HR}" 'BEGIN{printf "%.2f", n*c}')
    DAY=$(awk -v n="${N}" -v c="${CHIP_HR}" 'BEGIN{printf "%.0f", n*c*24}')
    echo "warm pool -> ${N} chips"
    echo "cost      -> \$${COST}/hr, \$${DAY}/day if left running"
    echo
    echo "Nodes take 2-4 min to arrive. Watch them:"
    echo "  kubectl --context=${CTX} get nodes -l cloud.google.com/gke-tpu-accelerator=tpu-v5-lite-podslice -w"
    echo
    echo "Turn it off when you're done:  bash $(basename "$0") off"
    ;;

  off)
    if "${K[@]}" get deployment/tpu-warm-pool >/dev/null 2>&1; then
      "${K[@]}" scale deployment/tpu-warm-pool --replicas=0 >/dev/null
      echo "warm pool -> 0 chips"
      echo "Nodes drain on their own in a few minutes. Confirm with: bash $(basename "$0") status"
    else
      echo "warm pool was never deployed; nothing to do"
    fi
    ;;

  status)
    if "${K[@]}" get deployment/tpu-warm-pool >/dev/null 2>&1; then
      WANT=$("${K[@]}" get deployment/tpu-warm-pool -o jsonpath='{.spec.replicas}')
      HAVE=$("${K[@]}" get deployment/tpu-warm-pool -o jsonpath='{.status.readyReplicas}')
      HAVE="${HAVE:-0}"
    else
      WANT=0; HAVE=0
      echo "(warm pool not deployed)"
    fi
    NODES=$(warm_nodes)
    COST=$(awk -v n="${HAVE}" -v c="${CHIP_HR}" 'BEGIN{printf "%.2f", n*c}')
    echo "placeholders requested : ${WANT}"
    echo "placeholders ready     : ${HAVE}"
    echo "TPU nodes up           : ${NODES}   (includes any student job running now)"
    echo "warm burn              : \$${COST}/hr"
    ;;

  *)
    echo "usage: $(basename "$0") {on [N]|off|status}" >&2
    exit 1
    ;;
esac
