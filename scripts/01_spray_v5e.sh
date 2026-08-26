#!/usr/bin/env bash
# v5e sibling of ai-infra-demo-2026-05/capacity/flex_spray_tpu.sh.
#
# WHY THIS EXISTS RATHER THAN CALLING THAT SCRIPT
#
# flex_spray_tpu.sh guards its flex zone list only when ACCEL=v6e-*:
#
#     if [[ "$MODE" == "flex" && "$ACCEL" == v6e-* ]]; then ZONES="${V6E_FLEX_ZONES}"
#
# A v5e flex run falls through to zone discovery, which returns every zone that
# offers v5e at all -- about 20 -- against a feature that exists in two. That is the
# same waste the v6e guard was written to prevent, just on a different chip.
#
# The v5e flex zone list, MEASURED by submitting a real FLEX_START request into each
# candidate on 2026-08-25. Only one zone accepted:
#
#     us-west4-a        accepted
#     us-central1-a     rejected, code 3, no flex pool
#     us-central1-b/c   v5e not offered at all, 0 accelerator types
#     europe-west4-b    rejected, code 3, no flex pool
#
# An earlier version of this file listed europe-west4-b as a flex zone, taken from the
# DWS Flex Dedicated table on an internal capacity dashboard, which showed 4/256 chips there. A
# real submit says otherwise. The dashboard reports pool SIZE, not whether your project
# can draw from it, and this is the second time that distinction has cost us -- the same
# trap produced a phantom 15,548-chip v6e pool in us-west1-c.
#
# Derive this list by submitting, not by reading a table. A rejection is instant and
# free, so the measurement costs nothing.
#
# us-central1 having no v5e flex pool is why a class running there waits on on-demand
# capacity and sees 20-minute cold starts.
#
#   MODE=flex     bash 01_spray_v5e.sh            # $0 while queued
#   MODE=ondemand ACCEL=v5litepod-1 bash 01_spray_v5e.sh
#   MODE=spot     ZONES="us-west4-a" bash 01_spray_v5e.sh
set -uo pipefail

PROJECT="${PROJECT:-${PROJECT:?set PROJECT to your GCP project id}}"
ACCEL="${ACCEL:-v5litepod-1}"
RUNTIME="${RUNTIME:-v2-alpha-tpuv5-lite}"
TAG="${TAG:-tpuspray}"
POLL_SECONDS="${POLL_SECONDS:-20}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-1800}"
MAX_RUN_DURATION="${MAX_RUN_DURATION:-604800s}"
MODE="${MODE:-flex}"

# Measured by submitting, 2026-08-25. See the header. Re-measure before trusting it.
V5E_FLEX_ZONES="${V5E_FLEX_ZONES:-us-west4-a}"

# On-demand and Spot are not restricted to the flex pools, so they get the wider
# list. These are the zones the dashboard shows carrying v5e single-host inventory.
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

# Same loud guard as the v6e script: submitting flex into a zone with no flex pool
# can only ever return code 3, and a retry loop will do it forever.
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
