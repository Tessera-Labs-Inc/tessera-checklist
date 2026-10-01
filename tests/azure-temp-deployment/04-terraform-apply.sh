#!/usr/bin/env bash
# Step 4 — run orchestration-final as the pipeline SPN only (client secret, isolated az config).
#   ./04-terraform-apply.sh plan | ./04-terraform-apply.sh
#
# Every AuthorizationFailed / 403 in the run is extracted to
# $WORK_DIR/authorization-failures.txt — that list is exactly what the roles are missing.
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$WORK_DIR/spn.env"
MODE="${1:-apply}"
export AZURE_CONFIG_DIR="$WORK_DIR/az-spn" ARM_USE_CLI=false
az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID" -o none
az account set --subscription "$SUB_ID"

ACR_ID="/subscriptions/$SUB_ID/resourceGroups/$CORE_RG/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME"
UAMI_ID="/subscriptions/$SUB_ID/resourceGroups/$CORE_RG/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$AKS_UAMI"
zone_id() { echo "/subscriptions/$HUB_SUB_ID/resourceGroups/$HUB_RG/providers/Microsoft.Network/privateDnsZones/$1"; }
# Key Vault is reached from wherever terraform runs. On the customer's self-hosted
# Azure DevOps agent that's the agent subnet; from a laptop it's this public IP.
RUNNER_IP="${RUNNER_IP:-$(curl -s https://api.ipify.org)}"
ADMIN_OID="${ADMIN_OID:-}" # platform engineer object ID: KV admin, blob data, AKS RBAC cluster admin (needed for Flux bootstrap)
POOL='vm_size = "Standard_D2s_v3", node_count = 1, enable_auto_scaling = true, min_count = 1, max_count = 1, max_pods = 30, tags = {}, os_disk_size_gb = 64, max_surge = "1", node_labels = {}'
# data/observability carry the stateful apps (etcd, ClickHouse, ZooKeeper) - more room, on
# DSv4 because dev's DSv3 quota is used up by the other pools + jumpbox.
POOL_DATA='vm_size = "Standard_D2s_v4", node_count = 1, enable_auto_scaling = true, min_count = 1, max_count = 3, max_pods = 30, tags = {}, os_disk_size_gb = 64, max_surge = "1", node_labels = {}'
POOL_OBS='vm_size = "Standard_D4s_v4", node_count = 1, enable_auto_scaling = true, min_count = 1, max_count = 3, max_pods = 30, tags = {}, os_disk_size_gb = 64, max_surge = "1", node_labels = {}'

ORCH_SOURCE="git::https://github.com/Tessera-Labs-Inc/terraform-azure-modules-orchestration-final.git?ref=${ORCH_REF}"
# Test-only escape hatch: some subscriptions can't create Azure Managed Redis in every
# region ("...is not supported for your subscription in <region>"). With REDIS_LOCATION
# set, use a local copy of orchestration-final whose database module puts ONLY the
# azurerm_managed_redis resource in that region (it's reached through its private
# endpoint in the VNet's region, which Azure supports cross-region). Nothing else -
# and nothing permission-related - changes.
if [ -n "${REDIS_LOCATION:-}" ]; then
  VENDOR="$WORK_DIR/vendor"
  rm -rf "$VENDOR" && mkdir -p "$VENDOR"
  git clone -q --depth 1 --branch "$ORCH_REF" \
    https://github.com/Tessera-Labs-Inc/terraform-azure-modules-orchestration-final.git "$VENDOR/orchestration"
  DB_REF=$(grep -oE 'terraform-azure-modules-database\?ref=[0-9a-f]+' "$VENDOR/orchestration/main.tf" | cut -d= -f2)
  git clone -q https://github.com/Tessera-Labs-Inc/terraform-azure-modules-database.git "$VENDOR/orchestration/database"
  git -C "$VENDOR/orchestration/database" checkout -q "$DB_REF"
  python3 - "$VENDOR" "$REDIS_LOCATION" <<'PY'
import re, sys
vendor, loc = sys.argv[1], sys.argv[2]
p = f"{vendor}/orchestration/database/main.tf"
s = open(p).read()
s, n = re.subn(r'(resource "azurerm_managed_redis" "this" \{[^}]*?location\s*=\s*)var\.location', rf'\g<1>"{loc}"', s, count=1)
assert n == 1, "azurerm_managed_redis location not found"
open(p, "w").write(s)
p = f"{vendor}/orchestration/main.tf"
s = open(p).read()
s, n = re.subn(r'source\s*=\s*"github\.com/Tessera-Labs-Inc/terraform-azure-modules-database\?ref=[0-9a-f]+"', 'source = "./database"', s)
assert n == 1, "database module source not found"
open(p, "w").write(s)
PY
  ORCH_SOURCE="$VENDOR/orchestration"
  echo "NOTE: test-only override - Managed Redis in ${REDIS_LOCATION} (database module ${DB_REF})"
fi

# PostgreSQL: Azure picks an availability zone when none is set, and the provider then
# refuses to "change" it back to null on the next apply. Pin whatever zone an existing
# server already has.
PG_ZONE=$(az postgres flexible-server show -g "$CORE_RG" -n "${NAME}-coredb-pg" --query availabilityZone -o tsv 2>/dev/null || true)
PG_ZONE_ARG=$( [ -n "$PG_ZONE" ] && echo ", zone = \"$PG_ZONE\"" || true )

TF_DIR="$WORK_DIR/terraform"
mkdir -p "$TF_DIR"
cat > "$TF_DIR/main.tf" <<EOF
terraform {
  backend "azurerm" {}
}

module "orchestration" {
  source = "${ORCH_SOURCE}"

  customer_name       = "${CUSTOMER}"
  environment         = "${ENVIRONMENT}"
  resource_group_name = "${CORE_RG}"
  location            = "${LOCATION}"
  subscription_id     = "${SUB_ID}"
  hub_subscription_id = "${HUB_SUB_ID}"

  # Networking: customer-provided /22 spoke VNet, egress via hub firewall,
  # peering created by the customer (enable_hub_peering = false).
  create_vnet              = false
  vnet_name                = "${SPOKE_VNET}"
  vnet_cidr                = "${SPOKE_CIDR}"
  enable_hub_peering       = false
  hub_resource_group_name  = "${HUB_RG}"
  hub_virtual_network_name = "${HUB_VNET}"
  hub_firewall_private_ip  = "${HUB_FIREWALL_IP}"
  enable_firewall          = false
  enable_bastion_host      = false
  enable_service_endpoints = true # KV/Storage/Sql endpoints on the subnets; KV network ACLs reference them (same as sandbox-internal-azure)

  # Hub Private DNS zones (checklist: *_private_dns_zone_id)
  private_dns_zone_id                            = "$(zone_id "$ZONE_AKS")"
  key_vault_private_dns_zone_id                  = "$(zone_id "$ZONE_KV")"
  key_vault_private_dns_zone_resource_group_name = "${HUB_RG}"
  key_vault_private_dns_zone_subscription_id     = "${HUB_SUB_ID}"
  postgres_private_dns_zone_id                   = "$(zone_id "$ZONE_PG")"
  redis_private_dns_zone_id                      = "$(zone_id "$ZONE_REDIS")"

  key_vault_public_network_access_enabled = true
  key_vault_allowed_ip_ranges             = ["${RUNNER_IP}/32"]
  keyvault_purge_protection_enabled       = false # temp env: allow purge on destroy

  # AKS (checklist: pre-created UAMI, named node RG, private cluster)
  aks_cluster_user_assigned_identity_id = "${UAMI_ID}"
  node_resource_group_name              = "${NODE_RG}"
  private_cluster_enabled               = true
  kubernetes_version                    = "${K8S_VERSION}"
  container_registry_id                 = "${ACR_ID}"

  admin_principal_ids = $( [ -n "$ADMIN_OID" ] && echo "{ platform = \"$ADMIN_OID\" }" || echo "{}" )

  # Temp-test sizing: smallest SKUs, one node per pool.
  system_node_pool        = { name = "system", ${POOL} }
  general_node_pool       = { name = "general", ${POOL}, node_taints = [] }
  data_node_pool          = { name = "data", ${POOL_DATA}, node_taints = [] }
  infra_node_pool         = { name = "infra", ${POOL}, node_taints = ["dedicated=infra:NoSchedule"] }
  observability_node_pool = { name = "observe", ${POOL_OBS}, node_taints = ["dedicated=observability:NoSchedule"] }
  gpu_node_pool           = { name = "gpu", vm_size = "Standard_NC4as_T4_v3", node_count = 0, enable_auto_scaling = true, min_count = 0, max_count = 1, max_pods = 30, os_disk_size_gb = 64, os_disk_type = "Managed", tags = {}, kubelet_disk_type = "OS", gpu_driver = "None", node_labels = {}, node_taints = {}, max_surge = "1" }

  core_postgres = { sku_name = "B_Standard_B1ms", storage_mb = 32768, backup_retention_days = 7${PG_ZONE_ARG} }
  redis         = { sku_name = "Balanced_B1", clustering_policy = "NoCluster", eviction_policy = "AllKeysLRU" } # B0 not offered to this subscription in eastus2

  create_windows_jumpbox     = false
  create_linux_jumpbox       = true
  vm_size                    = "Standard_D2s_v3"
  encryption_at_host_enabled = false # requires the EncryptionAtHost subscription feature
}
EOF

cd "$TF_DIR"
LOG="$WORK_DIR/terraform-${MODE}-$(date +%Y%m%d-%H%M%S).log"
set +e
{
  terraform init -input=false -upgrade \
    -backend-config="resource_group_name=${CORE_RG}" \
    -backend-config="storage_account_name=${TFSTATE_SA}" \
    -backend-config="container_name=${TFSTATE_CONTAINER}" \
    -backend-config="key=${NAME}.tfstate" \
    -backend-config="use_azuread_auth=true" &&
  terraform plan -input=false -out=tfplan &&
  { [ "$MODE" != apply ] || terraform apply -input=false -parallelism=20 tfplan; }
} 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

grep -oE "does not have authorization to perform action '[^']+'( over scope '[^']+')?|AuthorizationFailed[^\"]{0,300}|StatusCode=403[^\"]{0,300}" "$LOG" \
  | sort -u > "$WORK_DIR/authorization-failures.txt"
echo
echo "Log: $LOG"
if [ -s "$WORK_DIR/authorization-failures.txt" ]; then
  echo "Authorization failures ($(wc -l < "$WORK_DIR/authorization-failures.txt")):"
  cat "$WORK_DIR/authorization-failures.txt"
else
  echo "No authorization failures."
fi
exit "$rc"
