#!/usr/bin/env bash
# Step 3 — verify the SPN before running Terraform.
#   a) verify_azure_role_permissions.py: every Action/DataAction in the role files is granted
#   b) ABAC condition: as the SPN, assigning Owner must FAIL and assigning Reader must SUCCEED
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$WORK_DIR/spn.env"

echo "==> Effective-permission check"
python3 "$REPO_ROOT/scripts/verify_azure_role_permissions.py" \
  --principal-id "$SPN_OID" --subscription-id "$SUB_ID" --resource-group "$CORE_RG" \
  --hub-subscription-id "$HUB_SUB_ID" --hub-resource-group "$HUB_RG"

echo "==> ABAC condition check (signed in as the SPN, isolated az config)"
export AZURE_CONFIG_DIR="$WORK_DIR/az-spn"
az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID" -o none
az account set --subscription "$SUB_ID"
UAMI_PID=$(az identity show -g "$CORE_RG" -n "$AKS_UAMI" --query principalId -o tsv)
SCOPE="/subscriptions/$SUB_ID/resourceGroups/$CORE_RG"

if az role assignment create --assignee-object-id "$UAMI_PID" --assignee-principal-type ServicePrincipal \
     --role Owner --scope "$SCOPE" -o none 2>"$WORK_DIR/abac-owner.err"; then
  echo "FAIL: SPN was able to grant Owner - the ABAC condition is not in effect" >&2
  az role assignment delete --assignee "$UAMI_PID" --role Owner --scope "$SCOPE"
  exit 1
fi
grep -qi "AuthorizationFailed\|does not have authorization" "$WORK_DIR/abac-owner.err" \
  && echo "    OK: granting Owner refused" \
  || { echo "Unexpected error granting Owner:"; cat "$WORK_DIR/abac-owner.err"; exit 1; }

az role assignment create --assignee-object-id "$UAMI_PID" --assignee-principal-type ServicePrincipal \
  --role Reader --scope "$SCOPE" -o none
echo "    OK: granting Reader allowed"
az role assignment delete --assignee "$UAMI_PID" --role Reader --scope "$SCOPE"
echo "    OK: deleting Reader allowed"
az logout
