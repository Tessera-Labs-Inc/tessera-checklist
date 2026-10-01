# Shared settings for the Azure temp deployment test. Source this from every step:
#   source tests/azure-temp-deployment/env.sh
#
# Defaults target the Tessera "dev" subscription and simulate the customer's hub
# subscription with a separate hub resource group in the same subscription.

export SUB_ID="${SUB_ID:-b5835a01-2035-43f5-bd64-820d05a1ea83}"
export HUB_SUB_ID="${HUB_SUB_ID:-$SUB_ID}"
export LOCATION="${LOCATION:-eastus2}"

# customer_name / environment for the orchestration module (lowercase, a-z0-9-).
export CUSTOMER="${CUSTOMER:-rbactest}"
export ENVIRONMENT="${ENVIRONMENT:-temp}"
export NAME="tessera-${CUSTOMER}-${ENVIRONMENT}"
export SHORT="tsr${CUSTOMER}${ENVIRONMENT}" # alphanumeric names (ACR, storage)

# Resource groups (checklist: core RG + AKS node/cluster RG; hub lives in the hub subscription).
export CORE_RG="${NAME}-core-rg"
export NODE_RG="${NAME}-cluster-rg"
export HUB_RG="${NAME}-hub-rg"

# Networking (checklist: existing /22 spoke VNet, hub VNet with firewall egress).
export SPOKE_VNET="vnet-${NAME}"
export SPOKE_CIDR="10.93.0.0/22"
export HUB_VNET="vnet-${NAME}-hub"
export HUB_CIDR="10.90.0.0/24"
export HUB_NVA_SUBNET_CIDR="10.90.0.0/27"
export HUB_FIREWALL_IP="10.90.0.4" # stand-in for the customer's hub firewall (NAT VM)

# Customer-provided shared services (checklist: ACR + storage account in Tessera subscription).
export ACR_NAME="${SHORT}acr"
export TFSTATE_SA="${SHORT}tfstate"
export TFSTATE_CONTAINER="tfstate"
export AKS_UAMI="${NAME}-aks-identity"

# Pipeline service principal (checklist: SPN behind the Azure DevOps service connection).
export SPN_NAME="${NAME}-deployer"

# Private DNS zones pre-created in the hub (checklist: AKS, PostgreSQL, Redis, Key Vault, ACR, AI Foundry).
export ZONE_AKS="privatelink.${LOCATION}.azmk8s.io"
export ZONE_KV="privatelink.vaultcore.azure.net"
export ZONE_PG="privatelink.postgres.database.azure.com"
export ZONE_REDIS="privatelink.redis.azure.net"
export ZONE_ACR="privatelink.azurecr.io"
export ZONE_AI="privatelink.services.ai.azure.com"
export HUB_ZONES="$ZONE_AKS $ZONE_KV $ZONE_PG $ZONE_REDIS $ZONE_ACR $ZONE_AI"

# Orchestration module version under test.
export ORCH_REF="${ORCH_REF:-v0.10.2}"
export K8S_VERSION="${K8S_VERSION:-1.34}"

# Local working files (credentials, rendered terraform, logs) - never committed.
export WORK_DIR="${WORK_DIR:-$HOME/.tessera-azure-temp/${NAME}}"
mkdir -p "$WORK_DIR" && chmod 700 "$WORK_DIR"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
export ROLE_DIR="$REPO_ROOT/policies/azure"
