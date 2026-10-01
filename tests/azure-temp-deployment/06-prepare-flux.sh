#!/usr/bin/env bash
# Step 6 — after a successful apply, as an admin: prepare the kfleet cluster
# `sandbox2-azure` (cloned from sandbox-internal-azure) for this environment.
#
#   a) fill the post-apply placeholders in kfleet/clusters/sandbox2-azure from the
#      Terraform-written Key Vault secret `tessera-<c>--<e>--workload-identity`
#      and the AKS OIDC issuer
#   b) grant AcrPull on the shared registry (tsravaultdev, same as sandbox-internal-azure)
#      to the kubelet identity and the Flux controller identities - Terraform only
#      granted them on this environment's own ACR
#   c) seed the Key Vault secrets nothing in Terraform creates:
#      TLS cert (self-signed for *.${CLUSTER_DOMAIN}) and, with SOURCE_KV set, copies of
#      the manual secrets (victoriametrics, MCP credentials; langfuse is Terraform-managed) from another vault
#
#   KFLEET_DIR=~/platform-deployment/kfleet SOURCE_KV=private-sandbox-kv ./06-prepare-flux.sh
set -euo pipefail
source "$(dirname "$0")/env.sh"
az account set --subscription "$SUB_ID"

KFLEET_DIR="${KFLEET_DIR:-$HOME/platform-deployment/kfleet}"
KFLEET_CLUSTER="${KFLEET_CLUSTER:-sandbox2-azure}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-sandbox2-azure.tesseralabs.ai}"
SHARED_ACR="${SHARED_ACR:-tsravaultdev}"
SHARED_ACR_SUB="${SHARED_ACR_SUB:-951b7f30-6e08-4bd5-81a1-bd0cfc563867}"
SOURCE_KV="${SOURCE_KV:-}"                 # e.g. private-sandbox-kv (sandbox-internal-azure's vault)
SOURCE_PREFIX="${SOURCE_PREFIX:-tessera-private--sandbox--}"
SOURCE_KV_SUB="${SOURCE_KV_SUB:-929a6f81-f6c8-4d83-af8f-e387b58e5eb3}"

CLUSTER="${NAME}-cluster"
KV="${CUSTOMER}-${ENVIRONMENT}-kv"
PREFIX="tessera-${CUSTOMER}--${ENVIRONMENT}--"
CDIR="$KFLEET_DIR/clusters/$KFLEET_CLUSTER"
test -d "$CDIR" || { echo "kfleet cluster dir not found: $CDIR" >&2; exit 1; }

echo "==> Key Vault data access for $(az account show --query user.name -o tsv) on $KV"
ME=$(az ad signed-in-user show --query id -o tsv)
KV_ID=$(az keyvault show -n "$KV" -g "$CORE_RG" --query id -o tsv)
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Key Vault Secrets Officer" --scope "$KV_ID" -o none 2>/dev/null || true
for i in $(seq 1 30); do
  WI=$(az keyvault secret show --vault-name "$KV" -n "${PREFIX}workload-identity" --query value -o tsv 2>/dev/null) && break
  [ "$i" = 30 ] && { echo "cannot read ${PREFIX}workload-identity (RBAC propagation / network ACL?)" >&2; exit 1; }
  sleep 10
done
wi() { echo "$WI" | python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }

echo "==> Filling kfleet/clusters/$KFLEET_CLUSTER placeholders"
ISSUER=$(az aks show -g "$CORE_RG" -n "$CLUSTER" --query oidcIssuerProfile.issuerUrl -o tsv)
sed -i \
  -e "s#__SOURCE_CONTROLLER_CLIENT_ID__#$(wi source-controller)#" \
  -e "s#__IMAGE_REFLECTOR_CONTROLLER_CLIENT_ID__#$(wi image-reflector-controller)#" \
  -e "s#__EXTERNAL_SECRETS_CLIENT_ID__#$(wi external-secrets)#" \
  -e "s#__MILVUS_CLIENT_ID__#$(wi milvus)#" \
  -e "s#__KUBERNETES_OIDC_ISSUER__#${ISSUER}#" \
  "$CDIR/flux-system/flux-instance.yaml" "$CDIR/flux-system/runtime-info.yaml"
grep -rn '__[A-Z_]*__' "$CDIR" && { echo "unfilled placeholders remain" >&2; exit 1; } || true
STORAGE=$(az storage account list -g "$CORE_RG" --query "[?starts_with(name,'tessera')].name | [0]" -o tsv)
grep -q "MILVUS_AZURE_STORAGE_ACCOUNT: \"$STORAGE\"" "$CDIR/flux-system/runtime-info.yaml" || \
  echo "WARNING: storage account is '$STORAGE' - update MILVUS_AZURE_STORAGE_ACCOUNT in runtime-info.yaml"
echo "    tenant=$(wi tenantId) issuer=$ISSUER"

echo "==> AcrPull on $SHARED_ACR for kubelet + Flux identities"
ACR_ID=$(az acr show -n "$SHARED_ACR" --subscription "$SHARED_ACR_SUB" --query id -o tsv)
KUBELET_OID=$(az aks show -g "$CORE_RG" -n "$CLUSTER" --query identityProfile.kubeletidentity.objectId -o tsv)
PIDS="$KUBELET_OID"
for sa in source-controller image-reflector-controller helm-controller cluster-autoscaler; do
  PIDS="$PIDS $(az identity show -g "$CORE_RG" -n "${NAME}-${sa}-pod-uami" --query principalId -o tsv)"
done
for pid in $PIDS; do
  az role assignment create --assignee-object-id "$pid" --assignee-principal-type ServicePrincipal \
    --role AcrPull --scope "$ACR_ID" -o none
done

echo "==> TLS certificate secret tessera-${CUSTOMER}-${ENVIRONMENT}-cert (self-signed *.${CLUSTER_DOMAIN})"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout "$TMP/tls.key" -out "$TMP/tls.crt" \
  -subj "/CN=*.${CLUSTER_DOMAIN}" -addext "subjectAltName=DNS:*.${CLUSTER_DOMAIN},DNS:${CLUSTER_DOMAIN}" 2>/dev/null
python3 -c 'import json,sys; print(json.dumps({"tls.crt": open(sys.argv[1]).read(), "tls.key": open(sys.argv[2]).read()}))' \
  "$TMP/tls.crt" "$TMP/tls.key" > "$TMP/cert.json"
az keyvault secret set --vault-name "$KV" -n "tessera-${CUSTOMER}-${ENVIRONMENT}-cert" -f "$TMP/cert.json" -o none

if [ -n "$SOURCE_KV" ]; then
  echo "==> Copying manual secrets ${SOURCE_PREFIX}* from $SOURCE_KV -> ${PREFIX}* in $KV"
  for suffix in victoriametrics mcp--workiq mcp--sap-datasphere mcp--jira mcp--abapilot-ecc mcp--abapilot-s4; do
    if az keyvault secret show --vault-name "$SOURCE_KV" --subscription "$SOURCE_KV_SUB" -n "${SOURCE_PREFIX}${suffix}" \
         --query value -o tsv > "$TMP/v" 2>/dev/null; then
      az keyvault secret set --vault-name "$KV" -n "${PREFIX}${suffix}" -f "$TMP/v" -o none
      echo "    copied ${suffix}"
    else
      echo "    skipped ${suffix} (not in $SOURCE_KV)"
    fi
  done
  rm -f "$TMP/v"
else
  echo "NOTE: SOURCE_KV not set - create ${PREFIX}{victoriametrics,mcp--*} by hand for the apps that need them."
fi

echo
echo "Done. Next: commit kfleet/clusters/$KFLEET_CLUSTER, merge it to kfleet main so push-artifact"
echo "publishes the signed artifact, then run 07-flux-bootstrap.sh."
