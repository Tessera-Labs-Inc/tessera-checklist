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

TF_DIR="$WORK_DIR/terraform"
mkdir -p "$TF_DIR"
cat > "$TF_DIR/main.tf" <<EOF
terraform {
  backend "azurerm" {}
}

module "orchestration" {
  source = "git::https://github.com/Tessera-Labs-Inc/terraform-azure-modules-orchestration-final.git?ref=${ORCH_REF}"

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
  data_node_pool          = { name = "data", ${POOL}, node_taints = [] }
  infra_node_pool         = { name = "infra", ${POOL}, node_taints = ["dedicated=infra:NoSchedule"] }
  observability_node_pool = { name = "observe", ${POOL}, node_taints = ["dedicated=observability:NoSchedule"] }
  gpu_node_pool           = { name = "gpu", vm_size = "Standard_NC4as_T4_v3", node_count = 0, enable_auto_scaling = true, min_count = 0, max_count = 1, max_pods = 30, os_disk_size_gb = 64, os_disk_type = "Managed", tags = {}, kubelet_disk_type = "OS", gpu_driver = "None", node_labels = {}, node_taints = {}, max_surge = "1" }

  core_postgres = { sku_name = "B_Standard_B1ms", storage_mb = 32768, backup_retention_days = 7 }
  redis         = { sku_name = "Balanced_B0" }

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
