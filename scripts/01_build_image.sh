#!/usr/bin/env bash
# Build and push the custom course Docker image.
#
# We inherit from the standard scipy-notebook and bake in the kubernetes client.
# This saves several seconds on every student pod's cold start compared to running
# a pip install in a postStart lifecycle hook.
set -euo pipefail

PROJECT="${PROJECT:-${PROJECT:?set PROJECT to your GCP project id}}"
REGION="${REGION:-us-west4}"

REPO="${REGION}-docker.pkg.dev/${PROJECT}/course-images"
IMAGE="${REPO}/scipy-notebook:latest"

echo "==> checking if Artifact Registry repository exists"
if ! gcloud artifacts repositories describe course-images --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "    creating repository course-images in ${REGION}"

  # Cleanup policy: automatically delete untagged images older than 30 days.
  # Without this, stale image layers accumulate indefinitely and bill for storage.
  CLEANUP_POLICY=$(mktemp)
  trap 'rm -f "${CLEANUP_POLICY}"' EXIT
  cat > "${CLEANUP_POLICY}" <<'POLICY'
[
  {
    "name": "delete-untagged",
    "action": {"type": "Delete"},
    "condition": {
      "tagState": "untagged",
      "olderThan": "30d"
    }
  },
  {
    "name": "keep-recent-tagged",
    "action": {"type": "Keep"},
    "mostRecentVersions": {
      "keepCount": 5
    }
  }
]
POLICY

  gcloud artifacts repositories create course-images \
    --repository-format=docker \
    --location="${REGION}" \
    --description="Docker repository for course images" \
    --cleanup-policy-dry-run=false \
    --cleanup-policies="${CLEANUP_POLICY}" \
    --project="${PROJECT}"
fi

echo "==> configuring docker auth for Artifact Registry"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

echo "==> building image ${IMAGE}"
docker build -t "${IMAGE}" "$(dirname "$0")/../docker"

echo "==> pushing image"
docker push "${IMAGE}"

echo
echo "Done. The hub is configured to use this image by default via IMAGE_NAME."
echo "If IMAGE_NAME is not set, be sure to update k8s/jupyterhub-values.yaml to point to:"
echo "    ${IMAGE}"
