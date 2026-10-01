#!/usr/bin/env bash
# Step 2 — CUSTOMER side, run as an admin who can create role definitions and
# app registrations (User Access Administrator / Owner + Entra app registration).
#
# Creates the Tessera custom roles from policies/azure, the pipeline service
# principal, and assigns ONLY the least-privilege roles (no Contributor / UAA):
#   roles 01, 02            -> Tessera subscription
#   role 03 + ABAC condition -> Tessera subscription
#   role 05 (Key Vault data) -> core resource group only
#   hub role                -> hub resource group
#   Storage Blob Data Contributor -> tfstate storage account   (checklist)
#   AcrPull                 -> container registry              (checklist)
# SPN credentials are written to $WORK_DIR/spn.env (chmod 600), never to the repo.
set -euo pipefail
source "$(dirname "$0")/env.sh"
az account set --subscription "$SUB_ID"

create_or_update_role() {
  local file="$1" placeholder="$2" sub="$3"
  local rendered="$WORK_DIR/$(basename "$file")"
  sed "s#<${placeholder}>#${sub}#" "$file" > "$rendered"
  local name
  name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Name"])' "$rendered")
  # Role listing is eventually consistent, so don't trust an existence check: try to
  # create, and fall back to update when the tenant already has a role with this name.
  # (No "Id" in the file: update looks the role up by Name within its AssignableScopes.)
  local err
  if err=$(az role definition create --role-definition "@$rendered" -o none 2>&1); then
    echo "    created '$name'"
    return
  fi
  grep -q RoleDefinitionWithSameNameExists <<<"$err" || { echo "$err" >&2; return 1; }
  for i in $(seq 1 18); do
    if err=$(az role definition update --role-definition "@$rendered" -o none 2>&1); then
      echo "    updated '$name'"
      return
    fi
    sleep 10 # existing role not yet visible to update's lookup
  done
  echo "$err" >&2
  return 1
}

echo "==> Role definitions"
for f in "$ROLE_DIR"/tessera-deployment-role-01-*.json "$ROLE_DIR"/tessera-deployment-role-02-*.json \
         "$ROLE_DIR"/tessera-deployment-role-03-*.json "$ROLE_DIR"/tessera-deployment-role-05-*.json; do
  create_or_update_role "$f" TESSERA_SUBSCRIPTION_ID "$SUB_ID"
done
create_or_update_role "$ROLE_DIR/tessera-hub-dns-role.json" HUB_SUBSCRIPTION_ID "$HUB_SUB_ID"

echo "==> Waiting for the custom roles to replicate (new role definitions take a few minutes to resolve by name)"
for name in "Tessera Deployment 01 - Networking and Compute" "Tessera Deployment 02 - Data, DNS and Monitoring" \
            "Tessera Deployment 03 - Identity and Security" "Tessera Deployment 05 - Key Vault Data (core RG)"; do
  for i in $(seq 1 30); do
    az role definition list --name "$name" --scope "/subscriptions/$SUB_ID" --query '[0].name' -o tsv 2>/dev/null | grep -q . && break
    [ "$i" = 30 ] && { echo "role '$name' still not resolvable after 5 min" >&2; exit 1; }
    sleep 10
  done
done
for i in $(seq 1 30); do
  az role definition list --name "Tessera Deployment - Hub Private DNS and Peering" \
    --scope "/subscriptions/$HUB_SUB_ID" --query '[0].name' -o tsv 2>/dev/null | grep -q . && break
  [ "$i" = 30 ] && { echo "hub role still not resolvable after 5 min" >&2; exit 1; }
  sleep 10
done
echo "    all roles resolvable"

echo "==> Pipeline service principal"
if [ ! -f "$WORK_DIR/spn.env" ]; then
  creds=$(az ad sp create-for-rbac --name "$SPN_NAME" --years 1 -o json)
  APP_ID=$(echo "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["appId"])')
  SECRET=$(echo "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')
  TENANT=$(echo "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tenant"])')
  umask 077
  cat > "$WORK_DIR/spn.env" <<EOF
export ARM_CLIENT_ID=$APP_ID
export ARM_CLIENT_SECRET='$SECRET'
export ARM_TENANT_ID=$TENANT
export ARM_SUBSCRIPTION_ID=$SUB_ID
EOF
fi
source "$WORK_DIR/spn.env"
for _ in $(seq 1 12); do
  SPN_OID=$(az ad sp show --id "$ARM_CLIENT_ID" --query id -o tsv 2>/dev/null) && break || sleep 5
done
grep -q "^export SPN_OID=" "$WORK_DIR/spn.env" || echo "export SPN_OID=$SPN_OID" >> "$WORK_DIR/spn.env"
echo "    appId=$ARM_CLIENT_ID objectId=$SPN_OID"

assign() { # role scope [extra args...]
  local role="$1" scope="$2"; shift 2
  if [ -z "$(az role assignment list --assignee "$SPN_OID" --role "$role" --scope "$scope" --query '[0].id' -o tsv)" ]; then
    az role assignment create --assignee-object-id "$SPN_OID" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$scope" "$@" -o none
  fi
  echo "    $role @ $scope"
}

echo "==> Role assignments (least privilege only)"
SUB_SCOPE="/subscriptions/$SUB_ID"
assign "Tessera Deployment 01 - Networking and Compute" "$SUB_SCOPE"
assign "Tessera Deployment 02 - Data, DNS and Monitoring" "$SUB_SCOPE"
assign "Tessera Deployment 03 - Identity and Security" "$SUB_SCOPE" \
  --condition "$(cat "$ROLE_DIR/role-assignment-condition.txt")" --condition-version 2.0
assign "Tessera Deployment 05 - Key Vault Data (core RG)" "$SUB_SCOPE/resourceGroups/$CORE_RG"
assign "Tessera Deployment - Hub Private DNS and Peering" "/subscriptions/$HUB_SUB_ID/resourceGroups/$HUB_RG"
assign "Storage Blob Data Contributor" "$(az storage account show -g "$CORE_RG" -n "$TFSTATE_SA" --query id -o tsv)"
assign "AcrPull" "$(az acr show -g "$CORE_RG" -n "$ACR_NAME" --query id -o tsv)"

echo "Done. RBAC can take a few minutes to propagate before step 3."
