#!/usr/bin/env bash
# Preflight for a university TPU classroom. Read-only: nothing here costs money.
#
# Answers, per region, the three questions that gate a v5e classroom before
# capacity is ever in play:
#
#   1. Is v5litepod offered in the zone at all?
#   2. Does the project hold PodSlice quota there, and how much?
#   3. Is the region's TPU location list even visible to this project?
#
# The quota question is the one people get wrong. v5e has two quota families and
# only one of them matters:
#
#   TPU_LITE_DEVICE_V5    -> ct5l-  machine types. Almost always 0. GKE does not use it.
#   TPU_LITE_PODSLICE_V5  -> ct5lp- machine types. This is what GKE and the TPU API
#                            consume, including for a single chip (v5litepod-1 / 1x1).
#
# Asking support to raise Device quota when you needed PodSlice is a wasted round trip.
set -uo pipefail

PROJECT="${PROJECT:-${PROJECT:?set PROJECT to your GCP project id}}"
REGIONS="${REGIONS:-us-west4 us-central1 europe-west4 us-south1 us-east5 us-west1}"

echo "project: ${PROJECT}"
echo

printf '%-16s %10s %10s %10s %10s  %s\n' \
  REGION PODSLICE PREEMPT DEVICE PRE-DEV "v5litepod types in -a/-b"
printf '%-16s %10s %10s %10s %10s  %s\n' \
  "----------------" "--------" "--------" "--------" "--------" "------------------------"

for R in ${REGIONS}; do
  Q=$(gcloud compute regions describe "${R}" --project="${PROJECT}" \
        --format="value(quotas)" 2>/dev/null | tr ';' '\n')

  get() { echo "${Q}" | grep "'metric': '$1'" | grep -o "'limit': [0-9.]*" | grep -o "[0-9.]*$"; }

  POD=$(get TPU_LITE_PODSLICE_V5);        POD=${POD:-—}
  PRE=$(get PREEMPTIBLE_TPU_LITE_PODSLICE_V5); PRE=${PRE:-—}
  DEV=$(get TPU_LITE_DEVICE_V5);          DEV=${DEV:-—}
  PDV=$(get PREEMPTIBLE_TPU_LITE_DEVICE_V5);   PDV=${PDV:-—}

  TYPES=""
  for Z in "${R}-a" "${R}-b" "${R}-c"; do
    N=$(gcloud compute tpus accelerator-types list --zone="${Z}" --project="${PROJECT}" \
          --format="value(type)" 2>/dev/null | grep -c "^v5litepod-")
    [[ "${N}" -gt 0 ]] && TYPES="${TYPES}${Z##*-}:${N} "
  done
  [[ -z "${TYPES}" ]] && TYPES="none"

  printf '%-16s %10s %10s %10s %10s  %s\n' "${R}" "${POD}" "${PRE}" "${DEV}" "${PDV}" "${TYPES}"
done

echo
echo "PODSLICE is the column that matters. DEVICE being 0 is normal and harmless."
echo
echo "=== v5e DWS Flex zones, measured by submitting (2026-08-25) ==="
echo "  us-west4-a       accepted"
echo "  us-central1-a    rejected, code 3, no flex pool"
echo "  us-central1-b/c  v5e not offered at all"
echo "  europe-west4-b   rejected, code 3, no flex pool"
echo
echo "Only us-west4-a served v5e flex. An earlier version of this script listed"
echo "europe-west4-b too, read off a capacity dashboard showing 4/256 chips there."
echo "A real submit disagreed. The dashboard reports pool SIZE, not whether your"
echo "project can draw from it."
echo
echo "This matters for cold starts. Where there is no flex pool, the v5e-flex"
echo "ResourceFlavor can never place, half the queue quota is unusable, and every"
echo "job waits on on-demand capacity instead."
echo
echo "Re-measure rather than trusting this list. A rejection is instant and free:"
echo "  gcloud alpha compute tpus queued-resources create probe --node-id=probe \\"
echo "    --zone=ZONE --accelerator-type=v5litepod-1 --runtime-version=v2-alpha-tpuv5-lite \\"
echo "    --provisioning-model=FLEX_START --max-run-duration=3600s"
