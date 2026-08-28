#!/usr/bin/env bash
# Clean up JupyterHub PVCs and their underlying GCP disks at the end of the term.
#
# Because the StorageClass uses `reclaimPolicy: Retain`, deleting the PVC or the
# namespace will leave the underlying GCP disk intact and continuing to bill.
# This script safely deletes the PVCs, the Released PVs, and the actual GCP disks.
#
# Usage:
#   bash 10_cleanup_pvcs.sh [--dry-run]
#   bash 10_cleanup_pvcs.sh --execute

set -euo pipefail

PROJECT="${PROJECT:-${PROJECT:?set PROJECT to your GCP project id}}"
REGION="${REGION:-us-west4}"
CLUSTER="${CLUSTER:-tpu-notebooks}"
NAMESPACE="${NAMESPACE:-cmu-idl}"
DRY_RUN=1

if [[ "${1:-}" == "--execute" ]]; then
  DRY_RUN=0
  echo "WARNING: Running in EXECUTE mode. Data will be deleted."
else
  echo "Running in DRY-RUN mode. Pass --execute to actually delete resources."
fi

# Pin the context
CTX="gke_${PROJECT}_${REGION}_${CLUSTER}"
if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "${CTX}"; then
  gcloud container clusters get-credentials "${CLUSTER}" \
    --region="${REGION}" --project="${PROJECT}" >/dev/null 2>&1
fi
K=(kubectl --context="${CTX}")

echo "==> Finding PVCs in namespace: ${NAMESPACE}"
PVCS=$("${K[@]}" -n "${NAMESPACE}" get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.volumeName}{"\n"}{end}')

if [[ -z "${PVCS}" ]]; then
  echo "No PVCs found in namespace ${NAMESPACE}."
else
  echo "$PVCS" | while IFS=$'\t' read -r PVC_NAME PV_NAME; do
    echo "Found PVC: ${PVC_NAME} bound to PV: ${PV_NAME}"
    if [[ $DRY_RUN -eq 0 ]]; then
      echo "  Deleting PVC ${PVC_NAME}..."
      "${K[@]}" -n "${NAMESPACE}" delete pvc "${PVC_NAME}" || true
    fi
  done
fi

echo "==> Finding Released PVs with retain policy..."
# Find all PVs that are Released (meaning their PVC was deleted but they are retained)
PVS=$("${K[@]}" get pv -o json | jq -r '.items[] | select(.status.phase == "Released") | "\(.metadata.name)\t\(.spec.csi.volumeHandle)"')

if [[ -z "${PVS}" ]]; then
  echo "No Released PVs found."
else
  echo "$PVS" | while IFS=$'\t' read -r PV_NAME VOL_HANDLE; do
    if [[ "$VOL_HANDLE" != "null" && -n "$VOL_HANDLE" ]]; then
      # VOL_HANDLE format is projects/{project}/zones/{zone}/disks/{disk_name}
      # e.g. projects/my-project/zones/us-west4-b/disks/pvc-1234
      DISK_PROJECT=$(echo "$VOL_HANDLE" | awk -F'/' '{print $2}')
      DISK_ZONE=$(echo "$VOL_HANDLE" | awk -F'/' '{print $4}')
      DISK_NAME=$(echo "$VOL_HANDLE" | awk -F'/' '{print $6}')

      if [[ -n "$DISK_NAME" && -n "$DISK_ZONE" ]]; then
        echo "Found orphaned disk: ${DISK_NAME} in ${DISK_ZONE} (from PV: ${PV_NAME})"
        if [[ $DRY_RUN -eq 0 ]]; then
          echo "  Deleting GCP disk ${DISK_NAME}..."
          gcloud compute disks delete "${DISK_NAME}" --zone="${DISK_ZONE}" --project="${DISK_PROJECT}" --quiet || true
          
          echo "  Deleting Kubernetes PV ${PV_NAME}..."
          "${K[@]}" delete pv "${PV_NAME}" || true
        fi
      else
        echo "Could not parse volume handle for PV ${PV_NAME}: ${VOL_HANDLE}"
      fi
    else
      echo "PV ${PV_NAME} does not have a CSI volume handle."
    fi
  done
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  echo "This was a dry run. To permanently delete these PVCs, PVs, and GCP Disks,"
  echo "run this script again with the --execute flag:"
  echo "  bash $(basename "$0") --execute"
else
  echo "Cleanup complete."
fi
