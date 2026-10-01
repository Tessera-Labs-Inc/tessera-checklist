#!/usr/bin/env bash
# Step 7 — bootstrap Flux on the (private) AKS cluster, as an admin who is an AKS RBAC
# Cluster Admin (pass ADMIN_OID to step 4, or add yourself to the admin group).
#
#   a) copy the cosign-signed kfleet artifact (and its .sig) for the cluster from JFrog,
#      where kfleet's push-artifact workflow publishes it, into the shared ACR the
#      FluxInstance syncs from
#   b) run the kfleet `bootstrap-*-azure` steps through `az aks command invoke`, since
#      the API server is private: helm install flux-operator, apply cosign-pub +
#      flux-instance, wait for Ready
#   c) print FluxInstance / Kustomization status
set -euo pipefail
source "$(dirname "$0")/env.sh"
az account set --subscription "$SUB_ID"

KFLEET_DIR="${KFLEET_DIR:-$HOME/platform-deployment/kfleet}"
KFLEET_CLUSTER="${KFLEET_CLUSTER:-sandbox2-azure}"
SHARED_ACR="${SHARED_ACR:-tsravaultdev}"
SHARED_ACR_SUB="${SHARED_ACR_SUB:-951b7f30-6e08-4bd5-81a1-bd0cfc563867}"
ARTIFACT_TAG="${ARTIFACT_TAG:-latest}"
SRC="${SRC_REPO:-tesseralabs.jfrog.io/tessera-internal-local/kfleet/$KFLEET_CLUSTER}"
DST="${SHARED_ACR}.azurecr.io/tessera-dev/kfleet/$KFLEET_CLUSTER"
CLUSTER="${NAME}-cluster"
CDIR="$KFLEET_DIR/clusters/$KFLEET_CLUSTER/flux-system"

echo "==> ACR token for $SHARED_ACR"
TOKEN=$(az acr login -n "$SHARED_ACR" --subscription "$SHARED_ACR_SUB" --expose-token --query accessToken -o tsv)
ACR_USER=00000000-0000-0000-0000-000000000000
oras login "${SHARED_ACR}.azurecr.io" -u "$ACR_USER" --password-stdin <<<"$TOKEN" >/dev/null

if [ "${SKIP_ARTIFACT_COPY:-false}" != "true" ]; then
  echo "==> Copying $SRC:$ARTIFACT_TAG (+ cosign signature) -> $DST"
  DIGEST=$(oras resolve "$SRC:$ARTIFACT_TAG")
  SIG_TAG="${DIGEST/:/-}.sig"
  oras cp "$SRC:$ARTIFACT_TAG" "$DST:$ARTIFACT_TAG"
  oras cp "$SRC:$SIG_TAG" "$DST:$SIG_TAG" || {
    echo "No cosign signature $SIG_TAG at $SRC - the FluxInstance verifies signatures, so sync would fail." >&2
    exit 1
  }
fi

echo "==> Bootstrapping Flux Operator via az aks command invoke"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp "$CDIR/cosign-pub.yaml" "$CDIR/flux-instance.yaml" "$WORK/"
cd "$WORK"
az aks command invoke -g "$CORE_RG" -n "$CLUSTER" --file cosign-pub.yaml --file flux-instance.yaml --command "
set -e
helm registry login ${SHARED_ACR}.azurecr.io -u $ACR_USER -p '$TOKEN'
helm upgrade --install flux-operator oci://${SHARED_ACR}.azurecr.io/tessera-dev/charts/flux-operator \
  --namespace flux-system --create-namespace \
  --set multitenancy.enabled=true \
  --set image.repository=${SHARED_ACR}.azurecr.io/tessera-dev/flux-operator \
  --wait --timeout 10m
kubectl apply -f cosign-pub.yaml
kubectl apply -f flux-instance.yaml
kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=10m
"

echo "==> Status"
az aks command invoke -g "$CORE_RG" -n "$CLUSTER" --command \
  "kubectl -n flux-system get fluxinstance,ocirepository; kubectl get kustomizations,helmreleases -A" \
  --query logs -o tsv
