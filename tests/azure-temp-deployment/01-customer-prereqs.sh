#!/usr/bin/env bash
# Step 1 — CUSTOMER side, run as a subscription admin (NOT the deploy SPN).
#
# Creates everything the Azure onboarding checklist says the customer provides
# before Tessera runs Terraform:
#   - resource providers registered (so the SPN never needs to register them)
#   - core + hub resource groups
#   - hub VNet with a NAT VM standing in for the hub firewall (hub_firewall_private_ip)
#   - existing /22 spoke VNet, peered to the hub (checklist: Customer-owned peering)
#   - hub Private DNS zones, linked to hub + spoke VNets
#   - ACR and the Terraform state storage account
#   - user-assigned identity for the AKS cluster, with its checklist roles
set -euo pipefail
source "$(dirname "$0")/env.sh"
az account set --subscription "$SUB_ID"

echo "==> Registering resource providers"
for ns in Microsoft.Network Microsoft.Compute Microsoft.ContainerService Microsoft.ContainerRegistry \
          Microsoft.ManagedIdentity Microsoft.KeyVault Microsoft.Storage Microsoft.DBforPostgreSQL \
          Microsoft.Cache Microsoft.OperationalInsights Microsoft.OperationsManagement Microsoft.Insights \
          Microsoft.Monitor Microsoft.AlertsManagement Microsoft.Dashboard Microsoft.CognitiveServices \
          Microsoft.PolicyInsights; do
  az provider register --namespace "$ns" --subscription "$SUB_ID" -o none
done

echo "==> Resource groups"
az group create -n "$CORE_RG" -l "$LOCATION" -o none
az group create -n "$HUB_RG" -l "$LOCATION" --subscription "$HUB_SUB_ID" -o none

echo "==> Hub VNet + NAT VM (stand-in for the customer's hub firewall)"
az network vnet create --subscription "$HUB_SUB_ID" -g "$HUB_RG" -n "$HUB_VNET" -l "$LOCATION" \
  --address-prefixes "$HUB_CIDR" --subnet-name nva-subnet --subnet-prefixes "$HUB_NVA_SUBNET_CIDR" -o none
az network nsg create --subscription "$HUB_SUB_ID" -g "$HUB_RG" -n "${NAME}-nva-nsg" -o none
az network nsg rule create --subscription "$HUB_SUB_ID" -g "$HUB_RG" --nsg-name "${NAME}-nva-nsg" \
  -n AllowSpokeInbound --priority 100 --direction Inbound --access Allow --protocol '*' \
  --source-address-prefixes "$SPOKE_CIDR" --destination-address-prefixes '*' --destination-port-ranges '*' -o none
az network vnet subnet update --subscription "$HUB_SUB_ID" -g "$HUB_RG" --vnet-name "$HUB_VNET" -n nva-subnet \
  --network-security-group "${NAME}-nva-nsg" -o none
cat > "$WORK_DIR/nva-cloud-init.yaml" <<EOF
#cloud-config
write_files:
  - path: /etc/sysctl.d/99-ip-forward.conf
    content: net.ipv4.ip_forward=1
runcmd:
  - sysctl -p /etc/sysctl.d/99-ip-forward.conf
  - iptables -t nat -A POSTROUTING -s ${SPOKE_CIDR} -o eth0 -j MASQUERADE
EOF
if ! az vm show --subscription "$HUB_SUB_ID" -g "$HUB_RG" -n "${NAME}-nva" -o none 2>/dev/null; then
  az network public-ip create --subscription "$HUB_SUB_ID" -g "$HUB_RG" -n "${NAME}-nva-pip" --sku Standard -o none
  az network nic create --subscription "$HUB_SUB_ID" -g "$HUB_RG" -n "${NAME}-nva-nic" --vnet-name "$HUB_VNET" \
    --subnet nva-subnet --private-ip-address "$HUB_FIREWALL_IP" --public-ip-address "${NAME}-nva-pip" \
    --ip-forwarding true -o none
  az vm create --subscription "$HUB_SUB_ID" -g "$HUB_RG" -n "${NAME}-nva" --nics "${NAME}-nva-nic" \
    --image Ubuntu2204 --size Standard_B2s --admin-username azureuser --generate-ssh-keys \
    --custom-data "$WORK_DIR/nva-cloud-init.yaml" -o none
fi

echo "==> Spoke VNet (/22, no subnets - Terraform creates them)"
az network vnet create -g "$CORE_RG" -n "$SPOKE_VNET" -l "$LOCATION" --address-prefixes "$SPOKE_CIDR" -o none
SPOKE_ID=$(az network vnet show -g "$CORE_RG" -n "$SPOKE_VNET" --query id -o tsv)
HUB_ID=$(az network vnet show --subscription "$HUB_SUB_ID" -g "$HUB_RG" -n "$HUB_VNET" --query id -o tsv)

echo "==> Hub <-> spoke peering (customer-owned per checklist)"
az network vnet peering create -g "$CORE_RG" --vnet-name "$SPOKE_VNET" -n "${NAME}-to-hub" \
  --remote-vnet "$HUB_ID" --allow-vnet-access --allow-forwarded-traffic -o none
az network vnet peering create --subscription "$HUB_SUB_ID" -g "$HUB_RG" --vnet-name "$HUB_VNET" -n "${NAME}-from-hub" \
  --remote-vnet "$SPOKE_ID" --allow-vnet-access --allow-forwarded-traffic -o none

echo "==> Hub Private DNS zones, linked to hub + spoke VNets"
for zone in $HUB_ZONES; do
  az network private-dns zone create --subscription "$HUB_SUB_ID" -g "$HUB_RG" -n "$zone" -o none
  az network private-dns link vnet create --subscription "$HUB_SUB_ID" -g "$HUB_RG" -z "$zone" -n hub-link \
    -v "$HUB_ID" -e false -o none
  az network private-dns link vnet create --subscription "$HUB_SUB_ID" -g "$HUB_RG" -z "$zone" -n spoke-link \
    -v "$SPOKE_ID" -e false -o none
done

echo "==> ACR + Terraform state storage account"
az acr create -g "$CORE_RG" -n "$ACR_NAME" --sku Basic -o none
az storage account create -g "$CORE_RG" -n "$TFSTATE_SA" -l "$LOCATION" --sku Standard_LRS \
  --min-tls-version TLS1_2 --allow-blob-public-access false -o none
az storage container create --account-name "$TFSTATE_SA" -n "$TFSTATE_CONTAINER" --auth-mode login -o none || \
  az storage container create --account-name "$TFSTATE_SA" -n "$TFSTATE_CONTAINER" \
    --account-key "$(az storage account keys list -g "$CORE_RG" -n "$TFSTATE_SA" --query '[0].value' -o tsv)" -o none

echo "==> AKS cluster user-assigned identity + checklist roles"
az identity create -g "$CORE_RG" -n "$AKS_UAMI" -o none
UAMI_PID=$(az identity show -g "$CORE_RG" -n "$AKS_UAMI" --query principalId -o tsv)
AKS_ZONE_ID=$(az network private-dns zone show --subscription "$HUB_SUB_ID" -g "$HUB_RG" -n "$ZONE_AKS" --query id -o tsv)
az role assignment create --assignee-object-id "$UAMI_PID" --assignee-principal-type ServicePrincipal \
  --role "Private DNS Zone Contributor" --scope "$AKS_ZONE_ID" -o none
az role assignment create --assignee-object-id "$UAMI_PID" --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" --scope "/subscriptions/$SUB_ID/resourceGroups/$CORE_RG" -o none

echo "Customer prerequisites done."
