#!/usr/bin/env bash
# Delete everything and prove nothing is still billing.
#
# The verification at the end is not decoration. A TPU node left Ready is $1.20/hr,
# and a queued resource left in ACTIVE bills the same whether or not anyone is using
# it. Both survive a casual "I deleted the cluster".
set -uo pipefail

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
REGION="${REGION:-us-west4}"
CLUSTER="${CLUSTER:-tpu-notebooks}"
SPRAY_ZONES="${SPRAY_ZONES:-us-west4-a us-central1-a us-south1-a europe-west4-b europe-west4-a us-east5-a}"

echo "==> deleting cluster ${CLUSTER}"
gcloud container clusters delete "${CLUSTER}" \
  --region="${REGION}" --project="${PROJECT}" --quiet 2>&1 || echo "    already gone"

echo
echo "==> deleting any queued resources left by 01_spray_v5e.sh"
for Z in ${SPRAY_ZONES}; do
  for N in $(gcloud compute tpus queued-resources list --zone="${Z}" \
               --project="${PROJECT}" --filter="name~tpuspray" \
               --format="value(name)" 2>/dev/null); do
    echo "    ${Z}/${N}"
    gcloud compute tpus queued-resources delete "${N}" --zone="${Z}" \
      --project="${PROJECT}" --force --quiet >/dev/null 2>&1
  done
done

echo
echo "==> verification: anything below this line is still costing money"
echo
echo "--- clusters ---"
gcloud container clusters list --project="${PROJECT}" --filter="name:${CLUSTER}" 2>&1
echo "--- TPU VMs ---"
for Z in ${SPRAY_ZONES}; do
  gcloud compute tpus tpu-vm list --zone="${Z}" --project="${PROJECT}" \
    --format="value(name,state)" 2>/dev/null | sed "s/^/${Z}  /"
done
echo "--- queued resources ---"
for Z in ${SPRAY_ZONES}; do
  gcloud compute tpus queued-resources list --zone="${Z}" --project="${PROJECT}" \
    --format="value(name,state)" 2>/dev/null | sed "s/^/${Z}  /"
done
echo
echo "Empty output under all three headings means you are clean."
