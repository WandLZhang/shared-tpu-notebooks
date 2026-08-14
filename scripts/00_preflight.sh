#!/usr/bin/env bash
# Preflight for the shared TPU notebook cluster. Read-only: nothing here costs money.
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

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
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
echo "A region needs a non-zero PODSLICE limit and at least one zone offering"
echo "v5litepod types. Both true means you can build the cluster there."
echo
echo "Quota is a ceiling, not a promise. It says how many chips you are allowed to"
echo "hold, never how many the zone can hand you right now. Only a real submit"
echo "answers that, which is what 01_spray_v5e.sh is for."
