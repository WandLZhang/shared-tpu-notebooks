#!/usr/bin/env bash
# Put JupyterHub behind HTTPS and Identity-Aware Proxy.
#
# After this, the hub has a real URL and Google sign-in. No port-forward, no tunnel to
# babysit, and nothing that dies when the proxy pod moves.
#
# WHY THIS WORKS IN AN ORG THAT BLOCKS L4 LOAD BALANCERS
#
# A Service of type LoadBalancer defaults its source range to 0.0.0.0/0, and some orgs
# forbid a firewall rule that broad. A GKE Ingress never asks for one: Google Front Ends
# terminate the connection and only need 130.211.0.0/22 and 35.191.0.0/16 opened.
#
# TWO STEPS THIS SCRIPT CANNOT DO FOR YOU
#
#   1. The OAuth consent screen has to be configured once, by hand, in the console. IAP
#      refuses to serve until it exists. The script prints the link.
#   2. A Google-managed certificate takes 15 to 60 minutes to reach ACTIVE. The script
#      polls and tells you where it is rather than pretending it is instant.
set -euo pipefail

PROJECT="${PROJECT:-${PROJECT:?set PROJECT to your GCP project id}}"
REGION="${REGION:-us-west4}"
CLUSTER="${CLUSTER:-tpu-notebooks}"
NAMESPACE="${NAMESPACE:-class-sec-a}"
IP_NAME="${IP_NAME:-tpu-notebooks-ip}"
# Who may sign in. A group is the right answer for a course:
#   IAP_MEMBER="group:students@your-university.edu"
IAP_MEMBER="${IAP_MEMBER:-user:$(gcloud config get-value account 2>/dev/null)}"

CTX="gke_${PROJECT}_${REGION}_${CLUSTER}"
gcloud container clusters get-credentials "${CLUSTER}" \
  --region="${REGION}" --project="${PROJECT}" >/dev/null 2>&1
K=(kubectl --context="${CTX}")

echo "==> APIs"
gcloud services enable iap.googleapis.com compute.googleapis.com --project="${PROJECT}" >/dev/null

echo "==> static IP ${IP_NAME}"
if ! gcloud compute addresses describe "${IP_NAME}" --global --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud compute addresses create "${IP_NAME}" --global --project="${PROJECT}" >/dev/null
fi
IP=$(gcloud compute addresses describe "${IP_NAME}" --global --project="${PROJECT}" --format="value(address)")

# nip.io resolves <anything>.<ip>.nip.io to that IP, so the managed certificate can
# validate without us owning a DNS zone. Swap DOMAIN for a real name in production; the
# rest of this script is unchanged.
DOMAIN="${DOMAIN:-${IP}.nip.io}"
echo "    ${IP}  ->  ${DOMAIN}"

echo "==> BackendConfig, ManagedCertificate, Ingress"
sed -e "s|__DOMAIN__|${DOMAIN}|g" -e "s|__NAMESPACE__|${NAMESPACE}|g" \
  "$(dirname "$0")/../k8s/ingress-iap.yaml" | "${K[@]}" apply -f -

echo "==> granting ${IAP_MEMBER} access"
gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="${IAP_MEMBER}" \
  --role="roles/iap.httpsResourceAccessor" \
  --condition=None >/dev/null 2>&1 \
  && echo "    ok" \
  || echo "    could not bind; grant roles/iap.httpsResourceAccessor by hand"

cat <<EOF

==> ONE MANUAL STEP, do it now or IAP will refuse every request

    Configure the OAuth consent screen (internal), once per project:
    https://console.cloud.google.com/auth/branding?project=${PROJECT}

EOF

echo "==> waiting for the certificate (15-60 min is normal)"
for i in $(seq 1 80); do
  STATUS=$("${K[@]}" -n "${NAMESPACE}" get managedcertificate hub-cert \
             -o jsonpath='{.status.certificateStatus}' 2>/dev/null || true)
  LBIP=$("${K[@]}" -n "${NAMESPACE}" get ingress hub-ingress \
           -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  printf '\r  cert=%-18s ingress-ip=%-16s %ds' "${STATUS:-pending}" "${LBIP:-pending}" $((i*30))
  [[ "${STATUS}" == "Active" ]] && break
  sleep 30
done
echo

STATUS=$("${K[@]}" -n "${NAMESPACE}" get managedcertificate hub-cert \
           -o jsonpath='{.status.certificateStatus}' 2>/dev/null || true)

if [[ "${STATUS}" == "Active" ]]; then
  cat <<EOF

    https://${DOMAIN}

Sign in with a Google account in this org. IAP checks it before JupyterHub sees the
request, and the hub reads the verified identity from the X-Goog-Authenticated-User-Email
header, so there's no second login.
EOF
else
  cat <<EOF

Certificate is still "${STATUS:-pending}". That's normal for up to an hour. Check with:

  kubectl --context=${CTX} -n ${NAMESPACE} describe managedcertificate hub-cert

FailedNotVisible means the domain doesn't resolve to ${IP} yet. If it's still failing
after an hour, nip.io may be rejected by the CA; register a real domain, point an A
record at ${IP}, and re-run with DOMAIN=your.domain.
EOF
fi
