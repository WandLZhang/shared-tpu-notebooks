#!/usr/bin/env bash
# Find a zone that will actually give you a v5e chip, before a class of 300 finds out
# for you.
#
# The cluster does not need this script. Two failures look the same from inside GKE.
# In the first, the zone has no capacity at this moment. In the second, the zone can
# never supply what you request. A real submit separates them in seconds.
#
# DWS Flex exists in only a few zones for each accelerator. The public documentation
# has been wrong in both directions. A zone with no flex pool rejects at once:
#
#     FLEX_START provisioning model is not supported for accelerator type
#     "v5litepod-1" in location "..."
#
# This is error code 3. A retry never corrects it.
#
# A loop that uses twenty zones against a two-zone feature wastes most of its attempts.
# The result looks the same as a capacity shortage. The V5E_FLEX_ZONES guard below
# rejects a zone with no flex pool, and it gives the reason.
#
# Discover your own flex zones by running MODE=flex against a wide ZONES list once and
# keeping whichever ones do not return code 3. Then set V5E_FLEX_ZONES.
#
#   MODE=flex     bash 01_spray_v5e.sh            # $0 while queued
#   MODE=ondemand ACCEL=v5litepod-1 bash 01_spray_v5e.sh
#   MODE=spot     ZONES="us-west4-a" bash 01_spray_v5e.sh
set -uo pipefail

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
ACCEL="${ACCEL:-v5litepod-1}"
RUNTIME="${RUNTIME:-v2-alpha-tpuv5-lite}"
TAG="${TAG:-tpuspray}"
POLL_SECONDS="${POLL_SECONDS:-20}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-1800}"
MAX_RUN_DURATION="${MAX_RUN_DURATION:-604800s}"
MODE="${MODE:-flex}"

# Source: measured by real submits. Confirmed 2026-08-13.
V5E_FLEX_ZONES="${V5E_FLEX_ZONES:-us-west4-a europe-west4-b}"

# On-demand and Spot are not restricted to the flex pools, so they get the wider
# list. Set these to zones your project can actually reach.
V5E_WIDE_ZONES="${V5E_WIDE_ZONES:-us-west4-a us-central1-a us-south1-a europe-west4-b europe-west4-a us-east5-a}"

case "$MODE" in
  flex)     CREATE=(gcloud alpha compute tpus queued-resources create)
            EXTRA=(--provisioning-model=FLEX_START --max-run-duration="${MAX_RUN_DURATION}") ;;
  spot)     CREATE=(gcloud compute tpus queued-resources create); EXTRA=(--spot) ;;
  ondemand) CREATE=(gcloud compute tpus queued-resources create); EXTRA=() ;;
  *) echo "MODE must be flex, spot or ondemand, got '$MODE'" >&2; exit 1 ;;
esac

if [[ -z "${ZONES:-}" ]]; then
  if [[ "$MODE" == "flex" ]]; then
    ZONES="${V5E_FLEX_ZONES}"
    echo "MODE=flex: using the v5e flex pool zones (${ZONES}), not the full v5e zone list"
  else
    ZONES="${V5E_WIDE_ZONES}"
  fi
fi

# A flex submit into a zone with no flex pool always returns code 3. A retry loop
# repeats this without a limit. Stop it here.
if [[ "$MODE" == "flex" ]]; then
  overlap=""
  for z in ${ZONES}; do
    for f in ${V5E_FLEX_ZONES}; do [[ "$z" == "$f" ]] && overlap="${overlap} ${z}" && break; done
  done
  if [[ -z "${overlap}" ]]; then
    echo "ERROR: none of these zones has a v5e DWS Flex pool: ${ZONES}" >&2
    echo "       every submit would fail with code 3 'FLEX_START ... is not supported'." >&2
    echo "       v5e flex zones are: ${V5E_FLEX_ZONES}" >&2
    exit 1
  fi
  [[ "${overlap# }" != "${ZONES}" ]] && { echo "  dropping zones with no flex pool; keeping:${overlap}"; ZONES="${overlap# }"; }
fi

read -r -a ZONE_ARR <<< "${ZONES}"
STAMP="$(date +%m%d-%H%M%S)"
echo "spraying ${ACCEL} (MODE=${MODE}) across ${#ZONE_ARR[@]} zones: ${ZONE_ARR[*]}"
echo

submit() {
  local zone="$1" name="${TAG}-${ACCEL//./-}-${1}-${STAMP}" out
  if out=$("${CREATE[@]}" "${name}" \
      --node-id="${name}" --zone="${zone}" --project="${PROJECT}" \
      --accelerator-type="${ACCEL}" --runtime-version="${RUNTIME}" \
      "${EXTRA[@]}" --quiet 2>&1); then
    echo "  submitted  ${zone}"
  elif echo "${out}" | grep -qi "does not have permission"; then
    echo "  DENIED     ${zone}  (queue closed to this project, not capacity)"
  elif echo "${out}" | grep -qi "is not supported"; then
    echo "  NO POOL    ${zone}  (no flex pool here -- drop it from your zone list)"
  elif echo "${out}" | grep -qi "Request size can be at most"; then
    echo "  TOO BIG    ${zone}  ($(echo "${out}" | grep -o 'at most [0-9]*') chips in this zone)"
  else
    echo "  rejected   ${zone}  ($(echo "${out}" | tr '\n' ' '))"
  fi
}

for z in "${ZONE_ARR[@]}"; do submit "$z" & done; wait

echo
echo "polling for first ACTIVE (timeout ${MAX_WAIT_SECONDS}s)..."
WINNER="" ; WINNER_ZONE="" ; elapsed=0
while (( elapsed < MAX_WAIT_SECONDS )); do
  for zone in "${ZONE_ARR[@]}"; do
    line=$(gcloud compute tpus queued-resources list --zone="${zone}" \
            --project="${PROJECT}" --filter="name~${STAMP}" \
            --format="value(name,state)" 2>/dev/null)
    [[ -z "${line}" ]] && continue
    name="${line%%$'\t'*}" ; state="${line##*$'\t'}" ; state="${state#state=}"
    if [[ "${state}" == "ACTIVE" || "${state}" == "READY" ]]; then
      WINNER="${name}" ; WINNER_ZONE="${zone}" ; break 2
    fi
  done
  sleep "${POLL_SECONDS}" ; elapsed=$(( elapsed + POLL_SECONDS ))
  printf '\r  %ss elapsed' "${elapsed}"
done
echo

if [[ -z "${WINNER}" ]]; then
  echo "no zone granted ${ACCEL} within ${MAX_WAIT_SECONDS}s."
  [[ "$MODE" == "flex" ]] && echo "queued flex requests cost nothing until granted; leaving them parked is free."
  echo
  echo "  for Z in ${ZONE_ARR[*]}; do"
  echo "    for N in \$(gcloud compute tpus queued-resources list --zone=\$Z --project=${PROJECT} \\"
  echo "                 --filter=\"name~${STAMP}\" --format='value(name)'); do"
  echo "      gcloud compute tpus queued-resources delete \$N --zone=\$Z --project=${PROJECT} --force --quiet"
  echo "    done"
  echo "  done"
  exit 2
fi

echo "WON: ${WINNER} in ${WINNER_ZONE}"
echo "deleting losers so you are not billed twice..."
for zone in "${ZONE_ARR[@]}"; do
  [[ "${zone}" == "${WINNER_ZONE}" ]] && continue
  gcloud compute tpus queued-resources list --zone="${zone}" --project="${PROJECT}" \
    --filter="name~${STAMP}" --format="value(name)" 2>/dev/null | while read -r n; do
      [[ -n "$n" ]] && gcloud compute tpus queued-resources delete "$n" \
        --zone="${zone}" --project="${PROJECT}" --force --quiet >/dev/null 2>&1 \
        && echo "  deleted ${zone}/${n}"
    done
done

cat <<EOF

This proves the zone can serve v5e. The classroom itself runs on GKE, not on this
node -- the spray is here to pick the zone and to tell capacity failures apart from
configuration failures before a class of 300 hits it.

  gcloud compute tpus tpu-vm ssh ${WINNER} --zone=${WINNER_ZONE} --project=${PROJECT}

Tear down (a granted slice bills while ACTIVE):
  gcloud compute tpus queued-resources delete ${WINNER} --zone=${WINNER_ZONE} --project=${PROJECT} --force
EOF
