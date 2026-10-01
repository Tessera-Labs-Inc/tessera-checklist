# Tessera Azure Deployment Roles

These Azure custom role definitions, assigned together to the pipeline
service principal (the SPN behind the Azure DevOps Azure RM service
connection), are what Terraform uses to stand up and manage a full Tessera
environment on Azure. They replace the onboarding checklist's
**"SPN: Contributor + Role Assignment (User Access Administrator) on Tessera
Subscription"** and **"SPN: Private DNS Zone Contributor on Hub
Subscription"** grants.

Assigned on the **Tessera subscription**:

- `tessera-deployment-role-01-networking-compute.json` — spoke subnets,
  route tables, NSGs, private endpoints, jumpbox VMs, AKS and node pools,
  user-assigned managed identities and their federated credentials
- `tessera-deployment-role-02-data-dns-monitoring.json` — PostgreSQL
  Flexible Server, Azure Managed Redis, Key Vault (control plane), Storage,
  Private DNS fallback zones, Log
  Analytics / Azure Monitor / metric alerts, AI Foundry
- `tessera-deployment-role-03-identity-security.json` — role assignments,
  role-definition reads, subscription reads, resource provider registration.
  **Assign this one with the ABAC condition in
  `role-assignment-condition.txt`.**
- `tessera-deployment-role-04-optional-greenfield-network.json` — *only*
  when Terraform builds the network itself (`create_vnet`,
  `enable_firewall`, or `enable_bastion_host` = `true`)

Assigned on the **Tessera core resource group only** (`*-rg.json`):

- `tessera-deployment-role-05-keyvault-data-rg.json` — the Key Vault data
  plane: the secrets and customer-managed keys Terraform writes into the
  environment's own vault
- `tessera-deployment-role-06-optional-gitops-role-definition-rg.json` —
  *only* with `enable_gitops_kv_secrets_role = true` (default `false`)

Assigned on the **hub subscription**:

- `tessera-hub-dns-role.json` — A records in the pre-created hub Private
  DNS zones, zone-to-spoke VNet links, and hub-side VNet peering

The action lists are derived from what
`terraform-azure-modules-orchestration-final` (v0.7.1) and its pinned child
modules actually create: networking v0.4.0, security-groups v0.3.3,
keyvault v0.1.6, foundry v0.3.0, storage v0.1.13, database v0.4.2, aks
v0.3.1 (wrapping `Azure/terraform-azurerm-aks` v11.0.0), aks-pod-identity
v0.2.3. They were re-checked against v0.10.2 (foundry v0.4.0, database
v0.5.0, aks v0.6.0), which creates the same resource types. Every action name has been checked against the live Azure
provider-operations catalog (`az provider operation list`).

## Why several files, and no wildcard actions

Same reasoning as the AWS policy: every `Actions` / `DataActions` entry is a
fully-qualified operation — no `Microsoft.Network/*`, no
`Microsoft.KeyVault/vaults/secrets/*`. A wildcard is exactly what a
customer security review pushes back on, and on Azure it also silently
picks up every new operation the resource provider ships later.

The split follows the architecture (networking and compute, data and
supporting services, identity and security), and two of the boundaries are
also *assignment* boundaries that Azure forces on us:

- **Role 03 is separate so it can carry an ABAC condition.** Azure
  conditions attach to a role *assignment*, not a definition, and the
  condition is written against `roleAssignments/write` / `delete`. Keeping
  those actions in their own role keeps the condition from having to
  reason about anything else.
- **The hub role is separate because it's a different subscription.** Its
  `AssignableScopes` is the hub subscription, and it's assigned there (or
  narrower — see Usage).
- **Roles 05 and 06 are separate because they must never be assigned at
  subscription scope.** Role 05's DataActions would otherwise reach the
  secrets and keys in *every* vault in the customer's subscription. Role
  06's `roleDefinitions/write` would let the SPN edit its own custom roles,
  since roles 01–03 are assignable at the subscription. It could then add
  `*` to them without ever creating a role assignment, which bypasses the
  ABAC condition. At the core resource group, role 06 can only touch role
  definitions scoped inside that group.
- **Role 04 is separate because the checklist's topology never needs it.**
  The checklist is a BYO-VNet, hub-and-spoke deployment that egresses
  through the customer's hub firewall (`hub_firewall_private_ip`). Keeping
  VNet create/delete, public IPs, Azure Firewall, and Bastion in an
  unassigned role means the deploy SPN in that topology **cannot create a
  public IP at all**. Greenfield deployments simply assign it as well.

## The architecture, and why the deploy role needs each piece

A Tessera environment on Azure is an AKS cluster inside the customer's
spoke VNet, peered to a hub that owns egress (Azure Firewall) and Private
DNS. Supporting data services sit behind private endpoints or VNet
delegation, and every workload gets its own user-assigned managed identity
via AKS workload identity. Terraform owns the full lifecycle of all of it —
create, detect drift on every plan, update, destroy — which is why each
resource type has read/write/delete rather than just write.

### Networking (role 01)

Terraform carves subnets out of the customer's existing `/22` VNet
(`vnet_name`, `vnet_cidr`): AKS system/general/data/infra/gpu/
observability, PostgreSQL (delegated to
`Microsoft.DBforPostgreSQL/flexibleServers`), private endpoints, load
balancer, and jump server. Each gets a route table pointing `0.0.0.0/0` at
the hub firewall, and an NSG.

- `virtualNetworks/read` — the spoke VNet is consumed, not created
  (`create_vnet = false`). VNet write/delete live in role 04.
- `subnets/*` read/write/delete, `routeTables/*`, `routeTables/routes/*`,
  `networkSecurityGroups/*`, `securityRules/*` — Terraform owning each
  subnet, route table, NSG, and rule.
- The `join/action` operations (`subnets/join`, `routeTables/join`,
  `networkSecurityGroups/join`, `networkInterfaces/join`) — Azure checks
  these whenever something is *attached* to a subnet/route table/NSG/NIC:
  AKS node pools and the PostgreSQL server joining their subnets,
  route-table and NSG associations, jumpbox VMs joining their NIC.
- `subnets/joinViaServiceEndpoint/action` — required to put a subnet ID in
  a Key Vault or Storage account network ACL (the KV/Storage service
  endpoints on the AKS, DB, and jump server subnets).
- `virtualNetworks/join/action` — linking a Private DNS zone to the spoke
  VNet.
- `virtualNetworks/peer/action` and `virtualNetworkPeerings/*` — the
  spoke-side half of hub peering when `enable_hub_peering = true`. (The hub
  side is in the hub role.)
- `privateEndpoints/*` and `privateDnsZoneGroups/*` — private endpoints for
  Key Vault and Redis, with their DNS zone group registering the endpoint
  IP in the hub zone.
- `networkInterfaces/*` — jumpbox NICs, and reading back the NIC Azure
  creates behind each private endpoint for its IP address.
- `locations/operations/read`, `locations/operationResults/read` — the
  Network resource provider answers most writes asynchronously, and
  Terraform has to be allowed to poll the operation it just started.

### Compute — jumpboxes (role 01)

`create_windows_jumpbox` / `create_linux_jumpbox` (both default `true`)
create an admin VM in the jump server subnet. The admin password is
generated by Terraform and stored in Key Vault — no SSH key is created.

- `virtualMachines/*` (read/write/delete/start/powerOff/deallocate,
  `instanceView/read`) and `disks/*` — the VM and its managed OS disk
  (deleting the disk on destroy).
- `locations/operations/read`, `locations/diskOperations/read` —
  async-operation polling.

### AKS (role 01)

The cluster, its node pools, and the hooks that give pods an identity.

- `managedClusters/*` read/write/delete, `agentPools/*` — the control plane
  and the general, data, infra, observability, and GPU node pools. The
  `azapi_update_resource` PATCH the upstream module applies also lands on
  `managedClusters/write`.
- `maintenanceConfigurations/*` — the weekly node-OS patch window.
- `upgradeProfiles/read`, `locations/kubernetesversions/read` — version
  validation during plan.
- `availableAgentPoolVersions/read` — the azurerm provider checks every node
  pool's `orchestrator_version` against this list before creating the pool.
  **Without this action ARM doesn't return a 403.** It filters the list down
  to an empty one, and the apply fails with a misleading
  `Version "1.34.11" is not available for Node Pool …` error that never
  mentions authorization. Found in the temp-deployment test.
- `listClusterUserCredential/action` — `kubelogin` /
  `az aks get-credentials` for the Flux bootstrap. Local accounts are
  disabled, so `listClusterAdminCredential` is deliberately *not* granted;
  in-cluster access comes from the *Azure Kubernetes Service RBAC Cluster
  Admin* assignment Terraform makes to the deploy SPN.
- `userAssignedIdentities/assign/action` — attaching the checklist's
  pre-created AKS cluster identity (`aks_cluster_user_assigned_identity_id`)
  to the cluster. Azure checks this on the identity resource itself.
- `Microsoft.ContainerRegistry/registries/read` — the existing ACR
  (`container_registry_id`) is only a role-assignment scope; Terraform
  never creates or modifies a registry.

The AKS node resource group (`node_resource_group_name`, e.g.
`TesseraLabs-NonProd-cluster-rg`) and everything inside it (VMSS, the
cluster load balancer, its outbound public IP) are created by the AKS
resource provider using the cluster's own identity, not the deploy SPN.
That's why the deploy roles don't need VMSS or load-balancer write.

### Managed identities (role 01)

`userAssignedIdentities/*` and `federatedIdentityCredentials/*` — one
identity per workload (frontend, auth, llm, data-processing, data-foundry,
backend, the Flux controllers, cluster-autoscaler, external-secrets,
milvus), plus disk-CSI, external-dns, and the PostgreSQL CMK identity. Each
federated credential binds `system:serviceaccount:<ns>:<sa>` on the
cluster's OIDC issuer to one identity. These are ARM resources, not Entra
app registrations, so nothing here touches Microsoft Graph.

### Database — PostgreSQL Flexible Server (role 02)

The core PostgreSQL server (VNet-integrated, `public_network_access_enabled
= false`), its databases, and server parameters.

- `flexibleServers/*`, `configurations/*`, `databases/*` — the three
  resource types the database layer is made of.
- `locations/capabilities/read` — SKU/version validation.
- `locations/azureAsyncOperation/read`, `operationResults/read` —
  async-operation polling. A server create alone takes 5–15 minutes, all of
  it polled.

### Cache — Azure Managed Redis (role 02)

`azurerm_managed_redis` (`Microsoft.Cache/redisEnterprise`) and its
database, reached through a private endpoint.

- `redisEnterprise/*` and `databases/*` read/write/delete.
- `databases/listKeys/action` — Terraform reads the access key to write the
  Redis connection secret into Key Vault.
- `PrivateEndpointConnectionsApproval/action` — creating a private endpoint
  that is auto-approved requires this permission on the *target* resource.
  Without it the endpoint is stuck in "Pending".
- The `locations/*` and `operationResults/read` entries — async-operation
  polling.

### Key Vault (role 02)

One RBAC-mode vault per environment with a private endpoint into the hub
`privatelink.vaultcore.azure.net` zone, plus every secret Terraform writes:
database and Redis credentials, storage details, cluster secrets, workload
identity client IDs, DNS config, the jumpbox admin password, AI Foundry
endpoint, and SAP connection details.

- Control plane: `vaults/*` read/write/delete,
  `privateEndpointConnections/read`,
  `PrivateEndpointConnectionsApproval/action` (same auto-approval reason as
  Redis).
- `deletedVaults/read`, `locations/deletedVaults/read`,
  `locations/deletedVaults/purge/action` — the provider is configured with
  `recover_soft_deleted_key_vaults = true` and
  `purge_soft_delete_on_destroy = true`, so it looks for and recovers a
  soft-deleted vault of the same name across a teardown/redeploy. It purges
  on destroy unless purge protection is on.
- **Data plane** (`DataActions`, role 05) — the secrets themselves.
  `getSecret`/`setSecret`/`readMetadata`/`delete`, plus `recover` and
  `purge` for the same soft-delete reasons at the secret level. The vault
  is created with `enable_rbac_authorization = true` and the module does
  *not* grant the deploy SPN a Key Vault role on it, so these DataActions
  are how the SPN is allowed to write its own secrets.
- Key DataActions (`keys/create`, `read`, `update`, `delete`, `recover`,
  `purge`, `keyrotationpolicies/read`) cover the customer-managed key the
  database module creates when `encryption.mode = "cmk"` and no existing
  key is supplied. The provider reads a key's rotation policy on every
  refresh, even if none is set.

Because the vault doesn't exist until Terraform creates it, these
DataActions can't be scoped to the vault itself in advance. Role 05 is
assigned at the core resource group, where Terraform creates the vault, so
they never reach other vaults in the customer's subscription.

### Storage (role 02)

The application storage account (`public_network_access_enabled = false`,
ZRS, versioning, soft delete) and its `assets`, `logs`, and `milvus`
containers — or an existing account via `existing_storage_account_id`.

- `storageAccounts/*` read/write/delete, `blobServices/*` (versioning and
  soft-delete settings), and `containers/*`. Containers are created through
  ARM (`storage_account_id`), not the blob data plane.
- `listkeys/action`, `fileServices/read`, `queueServices/read` — the
  azurerm provider reads every service's properties back on every refresh,
  whether or not the account uses that service.

Blob *data* access is not in these roles. The checklist's separate
**Storage Blob Data Contributor on the storage account** (Terraform state
plus the software blob copy) stays as-is, scoped to that one account.

### Private DNS (role 02 / hub role)

The checklist has the customer pre-create every `privatelink.*` zone in the
hub subscription and pass in the `*_private_dns_zone_id` variables. Writes
against *those* zones are covered by the hub role.

Role 02's `privateDnsZones/*` and `virtualNetworkLinks/*` are the fallback
path. When a `*_private_dns_zone_id` is left empty, the Key Vault and
database modules create the zone locally in the Tessera resource group and
link it to the spoke VNet.

### Logging and monitoring (role 02)

- Log Analytics workspace, `OperationsManagement/solutions`
  (ContainerInsights), data collection rule and its association to the
  cluster — Container Insights for AKS.
- `workspaces/sharedkeys/action` — the OMS agent addon is configured with
  the workspace's shared key.
- `microsoft.monitor/accounts/*` — the Azure Monitor (managed Prometheus)
  workspace.
- `MetricAlerts/*`, `ActionGroups/Read`, `MetricDefinitions/Read`,
  `Metricnamespaces/Read`, `Compute/virtualMachineScaleSets/read` — the
  CPU/memory/storage/IOPS/availability alerts on PostgreSQL, Storage, and
  the AKS node-pool scale sets. Creating an alert requires reading the
  target's metric definitions, and the node VMSS alert is scoped to the
  node resource group. Action groups are referenced, never created.
- `Dashboard/grafana/*` — only when `enable_managed_grafana = true`.

### AI Foundry (role 02)

`CognitiveServices/accounts/*` and `deployments/*` create an `AIServices`
account and model deployment when `ai_foundry_create = true`. In the
checklist flow the customer provides `ai_foundry_id` instead. Then
Terraform only assigns *Cognitive Services User* on it to the backend
identity, and none of these create actions are exercised. The
`deletedAccounts` entries cover the provider's purge-on-destroy of
soft-deleted Cognitive accounts.

### Identity — role assignments (role 03)

Terraform creates these role assignments:

| Role | Assigned to | Scope |
|---|---|---|
| AcrPull | kubelet identity, Flux source/image-reflector/helm controllers, cluster-autoscaler | Container registry |
| Network Contributor | AKS cluster identity | AKS + LB subnets |
| Contributor | disk-CSI identity | AKS **node** resource group |
| Contributor | jumpbox VM system identities | **Tessera subscription** |
| Key Vault Administrator | `admin_principal_ids` | Key Vault |
| Key Vault Secrets User | external-secrets identities | Key Vault |
| Key Vault Crypto User | PostgreSQL CMK identity | CMK key |
| Storage Blob Data Contributor | frontend, llm, data-processing, data-foundry, backend, milvus identities; `admin_principal_ids` and jumpbox identities | Storage account |
| Azure Kubernetes Service RBAC Cluster Admin / Reader | admin group + deploy SPN / viewer groups | AKS cluster |
| DNS Zone Contributor, Reader | external-dns identity (only with a public `azure_dns_zone_id`) | DNS zone / resource group |
| Cognitive Services User | backend identity | AI Foundry account |

- `roleAssignments/read/write/delete` — creating and removing those.
- `roleDefinitions/read` — resolving built-in role names to IDs.
  `roleDefinitions/write`/`delete` are deliberately **not** in role 03 (see
  roles 05/06 above). They're only needed for the optional GitOps
  `<cluster>-secrets-read-gitops` custom role, which Terraform creates
  scoped to the vault but never assigns. That's role 06, at the core
  resource group.
- `Microsoft.Resources/subscriptions/read`,
  `subscriptions/resourceGroups/read` — the `azurerm_subscription` /
  `azurerm_client_config` data sources and resource-group lookups.
- `<Namespace>/register/action` for the resource providers Tessera uses —
  the azurerm provider registers missing providers on first use (see
  Practical notes).

## Guardrails

AWS IAM has explicit `Deny` statements. An Azure custom role has nothing
equivalent: `NotActions` only subtracts from that same role's `Actions`,
and on an enumerated role with no wildcards there's nothing to subtract.
The AWS guardrails map to three Azure mechanisms instead.

**1. ABAC condition on role 03 (`role-assignment-condition.txt`).** This is
the Azure equivalent of the AWS `iam:PassRole` condition and the most
important guardrail. Without it, `roleAssignments/write` would let the SPN
grant *any* role — including Owner — to *any* principal, which is the same
as holding Owner. The condition restricts both creating and deleting
assignments to exactly the 13 built-in roles in the table above. Owner,
User Access Administrator, Role Based Access Control Administrator, and
every other role are refused with `AuthorizationFailed`, whoever the
principal is.

**2. Not granted at all.** Every role here is an explicit allow-list, so
these can't happen under these roles:

- **No Entra ID changes.** Azure RBAC can't grant Microsoft Graph
  permissions, and none are requested. The SPN can't create users, groups,
  app registrations, service principals, or client secrets. Workload
  identity uses user-assigned managed identities, which are ARM resources.
- **No SSH key resources.** `Microsoft.Compute/sshPublicKeys` isn't
  granted; jumpboxes use a generated password stored in Key Vault.
- **No public IPs** in the checklist (BYO-VNet) topology — those live in
  the optional role 04.
- **No disabling security telemetry.** Nothing in `Microsoft.Security`
  (Defender for Cloud), `Microsoft.Insights/diagnosticSettings`, the
  activity log, `Microsoft.PolicyInsights` remediation, or
  `Microsoft.Authorization/policyAssignments` /
  `policyExemptions` — so the SPN can't switch off Defender, delete a
  diagnostic setting, or exempt itself from a policy.
- **No subscription, management-group, or resource-group changes.** No
  `resourceGroups/write` or `delete` (the resource groups are pre-created
  per the checklist), no locks, no `Microsoft.Management` or
  `Microsoft.Subscription`.
- **No Owner-only operations** on Key Vault or Storage: no vault access
  policies, no storage account SAS key rotation.

**3. Optional Azure Policy deny (`guardrails/tessera-guardrails-initiative.json`).**
Two built-in policies with `effect = Deny` for the controls that matter
most if Terraform configuration ever drifts:

- **No public PostgreSQL** — *Public network access should be disabled for
  PostgreSQL flexible servers* (`5e1de0e3-…`). This mirrors the AWS
  `DenyRDSPublicAccess`.
- **No public blob access** — *Storage account public access should be
  disallowed* (`4fa4b6c0-…`). This mirrors the AWS `DenyMakingS3Public`.

Unlike an AWS deny statement, an Azure Policy deny applies to *every*
principal at the assigned scope, not just this SPN — so assign it at the
Tessera core resource group. *Storage accounts should disable public
network access* is deliberately **not** included: service endpoints (the
checklist's Azure DevOps subnet) require public network access set to
"selected networks", and that policy would block them.

## Practical notes

- **Contributor is in the ABAC allow-list, and that's the biggest residual
  risk.** Two module behaviors need it:
  - The disk-CSI identity gets Contributor on the AKS node resource group.
  - The jumpbox VMs' system identities get Contributor on the **whole
    Tessera subscription**, because `create_*_jumpbox` defaults to `true`.

  Since the SPN can create a managed identity and grant it Contributor, it
  can effectively act as Contributor. That's still strictly less than the
  checklist's Contributor + User Access Administrator, but it's the first
  thing a security review will flag. To close the gap:
  1. Set `create_windows_jumpbox` / `create_linux_jumpbox` to `false`, or
     scope the jumpbox assignments to the core resource group in
     `terraform-azure-modules-orchestration-final`.
  2. Remove `b24988ac-6180-42a0-ab88-20f7382dd24c` from the condition.

  The disk-CSI assignment could likewise move to a narrower role.
- **The deploy SPN is made AKS RBAC Cluster Admin by Terraform**
  (`data.azurerm_client_config.current.object_id` is appended to
  `azure_rbac_admin_group_object_ids`). That's how the Flux bootstrap
  reaches the cluster; it isn't part of these role definitions.
- **Resource provider registration:** the azurerm provider's default
  (`resource_provider_registrations` unset = `"legacy"`) tries to register
  a long list of providers, many more than Tessera uses. Role 03 grants
  `register/action` only for the providers Tessera does use. Either:
  1. pre-register everything during onboarding (`az provider register -n
     <ns>` for Microsoft.Network, Compute, ContainerService,
     ContainerRegistry, ManagedIdentity, KeyVault, Storage, DBforPostgreSQL,
     Cache, OperationalInsights, OperationsManagement, Insights, Monitor,
     AlertsManagement, Dashboard, CognitiveServices, PolicyInsights), or
  2. set `resource_provider_registrations = "none"` in the orchestration
     module's provider blocks, and drop the `register/action` entries from
     role 03.

  The checklist's "Verify SPN permissions, required resource providers" step
  is where this gets confirmed.
- **AKS cluster identity (customer-created UAMI):** the checklist's
  *Private DNS Zone Contributor on Hub Sub + Network Contributor on Tessera
  Sub (VNET/LB subnet) + Contributor on AKS RG* grants for that identity
  are made by the customer, not by this SPN, and are unchanged.
  Terraform's own `Network Contributor`-on-subnet assignment for the
  cluster identity overlaps with them harmlessly.
- **AcrPull for the SPN** (checklist) stays a built-in assignment on the
  registry, separate from these roles.
- **Hub peering** is in the hub role for `enable_hub_peering = true`. If
  the customer creates the peering themselves (the checklist lists it as
  Customer-owned), the peering actions are simply never exercised.
- **Async-operation reads** (`locations/operations/read`,
  `operationResults/read`, `azureAsyncOperation/read`, and so on) look like
  noise but aren't optional. Without them Terraform starts a long-running
  create, then fails with `AuthorizationFailed` while polling for its
  result — leaving a half-created resource behind.

## Usage

1. Fill in the scopes and create the role definitions. Each must be
   created in the subscription named in its `AssignableScopes`:

   ```bash
   TESSERA_SUB=<tessera-subscription-id>
   HUB_SUB=<hub-subscription-id>
   for f in policies/azure/tessera-deployment-role-0*.json; do   # skip 04 / 06 if unused
     sed "s/<TESSERA_SUBSCRIPTION_ID>/$TESSERA_SUB/" "$f" > /tmp/role.json
     az role definition create --role-definition @/tmp/role.json
   done
   sed "s/<HUB_SUBSCRIPTION_ID>/$HUB_SUB/" policies/azure/tessera-hub-dns-role.json > /tmp/role.json
   az role definition create --role-definition @/tmp/role.json
   ```

   Skip role 04 for a BYO-VNet deployment, and role 06 unless
   `enable_gitops_kv_secrets_role = true`.

2. Assign them to the pipeline SPN. Use its **object ID** (Enterprise
   application → Object ID), not the client ID:

   ```bash
   SPN_OID=<pipeline-spn-object-id>
   SCOPE=/subscriptions/$TESSERA_SUB
   for r in "Tessera Deployment 01 - Networking and Compute" \
            "Tessera Deployment 02 - Data, DNS and Monitoring"; do
     az role assignment create --assignee-object-id "$SPN_OID" \
       --assignee-principal-type ServicePrincipal --role "$r" --scope "$SCOPE"
   done
   az role assignment create --assignee-object-id "$SPN_OID" \
     --assignee-principal-type ServicePrincipal \
     --role "Tessera Deployment 03 - Identity and Security" --scope "$SCOPE" \
     --condition "$(cat policies/azure/role-assignment-condition.txt)" \
     --condition-version 2.0
   az role assignment create --assignee-object-id "$SPN_OID" \
     --assignee-principal-type ServicePrincipal \
     --role "Tessera Deployment 05 - Key Vault Data (core RG)" \
     --scope "$SCOPE/resourceGroups/<core-rg>"     # never the subscription
   az role assignment create --assignee-object-id "$SPN_OID" \
     --assignee-principal-type ServicePrincipal \
     --role "Tessera Deployment - Hub Private DNS and Peering" \
     --scope /subscriptions/$HUB_SUB
   ```

   **Scope:** roles 01–03 go at the Tessera subscription. The AKS node
   resource group is created by AKS at apply time, and Terraform assigns a
   role on it, so a role-03 scope narrower than the subscription won't
   cover it. Roles 05 and 06 go at the core resource group only.

   The hub role can be narrowed from the hub subscription to the resource
   group holding the hub Private DNS zones and the hub VNet.

3. Remove the checklist's Contributor, User Access Administrator, and
   hub-wide Private DNS Zone Contributor grants from the SPN. Keep AcrPull
   on the registry and Storage Blob Data Contributor on the state/copy
   storage account.

4. Optional: assign the guardrail initiative at the Tessera core
   resource group:

   ```bash
   az policy set-definition create --name tessera-guardrails \
     --display-name "Tessera deployment guardrails" \
     --definitions @policies/azure/guardrails/tessera-guardrails-initiative.json \
     --subscription "$TESSERA_SUB"
   az policy assignment create --name tessera-guardrails \
     --policy-set-definition tessera-guardrails \
     --scope /subscriptions/$TESSERA_SUB/resourceGroups/<core-rg>
   ```

## Verifying a principal has these permissions

`.github/workflows/verify-azure-role-permissions.yml` checks a live service
principal against every `Actions` and `DataActions` entry in this
directory's role files. Run it from the Actions tab (`workflow_dispatch`)
with the SPN's object ID and the subscription IDs. It fails the run and
lists exactly which permissions are missing or denied.

Azure has no counterpart to `iam:SimulatePrincipalPolicy`, so
`scripts/verify_azure_role_permissions.py` evaluates permissions the way
ARM does:

1. Lists the principal's role assignments at or above each scope
   (`atScope()` returns assignments at *and above* the scope, so
   management-group and root assignments count). Group-inherited
   assignments are included too. Each role file is checked at the scope
   it's meant to be assigned at: the subscription, the core resource group
   (`*-rg.json`), or the hub.
2. Expands each role's `Actions − NotActions` and
   `DataActions − NotDataActions` with wildcard matching.
3. Removes anything a deny assignment blocks.

It also warns, without failing, in two cases:

- The principal still holds Owner, Contributor, User Access Administrator,
  or RBAC Administrator.
- `roleAssignments/write` is granted without an ABAC condition.

It doesn't evaluate the *content* of ABAC conditions or Azure Policy
effects.

The workflow signs in via OIDC as a separate verifier identity (repo
variables `AZURE_VERIFIER_CLIENT_ID` and `AZURE_TENANT_ID`), not as the SPN
being tested. That identity needs **Reader** on the Tessera and hub
subscriptions, which covers `roleAssignments/read`, `roleDefinitions/read`,
and `denyAssignments/read`. Without it, the check stops with a clear error
(exit code 2) instead of a partial report.

The same script runs locally after `az login`:

```bash
python3 scripts/verify_azure_role_permissions.py \
  --principal-id <spn-object-id> --subscription-id <tessera-sub> \
  --resource-group <core-rg> --hub-subscription-id <hub-sub>
```
