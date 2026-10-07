#!/usr/bin/env bash
# Step 5 — tear everything down.
#   a) terraform destroy AS THE SPN (proves the roles can also decommission)
#   b) as the admin: delete the SPN's role assignments, the app registration,
#      the customer prerequisite resource groups, and (optionally) the role definitions.
#
#   ./05-teardown.sh                 # destroy + clean up, keep the custom role definitions
#   DELETE_ROLES=true ./05-teardown.sh
set -euo pipefail
source "$(dirname "$0")/env.sh"
if [ "$CREDENTIAL_STORE_TEST" = false ]; then
  source "$WORK_DIR/spn.env"
fi

if [ -f "$WORK_DIR/terraform/main.tf" ]; then
  if [ "$CREDENTIAL_STORE_TEST" = true ]; then
    echo "==> terraform destroy as the Platform admin"
    (unset ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_TENANT_ID AZURE_CONFIG_DIR; \
      export ARM_USE_CLI=true ARM_SUBSCRIPTION_ID="$SUB_ID"; \
      cd "$WORK_DIR/terraform"; terraform destroy -input=false -auto-approve -parallelism=20 \
      2>&1 | tee "$WORK_DIR/terraform-destroy-$(date +%Y%m%d-%H%M%S).log")
  else
    echo "==> terraform destroy as the SPN"
    (
      export AZURE_CONFIG_DIR="$WORK_DIR/az-spn" ARM_USE_CLI=false
      az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID" -o none
      cd "$WORK_DIR/terraform"
      terraform destroy -input=false -auto-approve -parallelism=20 2>&1 | tee "$WORK_DIR/terraform-destroy-$(date +%Y%m%d-%H%M%S).log"
    ) || echo "WARNING: terraform destroy did not finish cleanly - see the log; continuing with admin cleanup"
  fi
fi

echo "==> Admin cleanup"
az account set --subscription "$SUB_ID"
if [ "$CREDENTIAL_STORE_TEST" = false ]; then
  for id in $(az role assignment list --assignee "$SPN_OID" --all --query '[].id' -o tsv); do
    az role assignment delete --ids "$id"
  done
  az ad app delete --id "$ARM_CLIENT_ID" || true
fi
az group delete -n "$NODE_RG" --yes --no-wait 2>/dev/null || true
az group delete -n "$CORE_RG" --yes
az group delete -n "$HUB_RG" --subscription "$HUB_SUB_ID" --yes
# Soft-deleted Key Vaults keep their name reserved for the retention period.
if [ "$CREDENTIAL_STORE_TEST" = true ]; then
  for kv in "${CUSTOMER}-${ENVIRONMENT}-kv" "${CUSTOMER}-${ENVIRONMENT}-cs-kv"; do
    if [ "$(az keyvault list-deleted --query "[?name=='$kv']|[0].name" -o tsv)" = "$kv" ]; then
      az keyvault purge -n "$kv"
    fi
  done
else
  for kv in $(az keyvault list-deleted --query "[?contains(name,'${CUSTOMER}')].name" -o tsv); do
    az keyvault purge -n "$kv" || true
  done
fi

if [ "$CREDENTIAL_STORE_TEST" = false ] && [ "${DELETE_ROLES:-false}" = "true" ]; then
  for name in "Tessera Deployment 01 - Networking and Compute" "Tessera Deployment 02 - Data, DNS and Monitoring" \
              "Tessera Deployment 03 - Identity and Security" "Tessera Deployment 05 - Key Vault Data (core RG)" \
              "Tessera Deployment - Hub Private DNS and Peering"; do
    az role definition delete --name "$name" --custom-role-only true || true
  done
fi
if [ "$CREDENTIAL_STORE_TEST" = false ]; then
  rm -f "$WORK_DIR/spn.env"
fi
echo "Teardown complete."
