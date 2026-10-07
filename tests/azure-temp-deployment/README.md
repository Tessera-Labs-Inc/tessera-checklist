# Azure temp deployment — testing the Tessera deployment roles end to end

This runbook stands up a throwaway Tessera environment on Azure. The
Terraform run uses **only** the least-privilege roles in `policies/azure`: no
Contributor and no User Access Administrator. Any permission the roles are
missing shows up as an `AuthorizationFailed` error in the Terraform log.

It plays both sides of the onboarding checklist:

| Step | Who | Script | Checklist items covered |
|---|---|---|---|
| 1 | Customer admin | `01-customer-prereqs.sh` | Resource providers, core/hub RGs, existing `/22` VNet, hub firewall (a NAT VM stands in), hub–spoke peering, hub Private DNS zones + VNet links, ACR, storage account, AKS UAMI with its Private DNS Zone Contributor + Network Contributor roles |
| 2 | Customer admin | `02-create-roles-and-spn.sh` | The pipeline SPN, with the Tessera custom roles in place of Contributor + UAA / Private DNS Zone Contributor: roles 01–03 at the subscription, role 05 at the core RG, and the hub role at the hub RG. Also Storage Blob Data Contributor on the state account and AcrPull on the ACR. |
| 3 | Tessera | `03-verify.sh` | "Verify SPN permissions": an effective-permission check, plus an ABAC proof (granting Owner is refused, granting Reader works) |
| 4 | Tessera | `04-terraform-apply.sh` | "Terraform Apply": orchestration-final run as the SPN with its client secret only |
| 6 | Tessera admin | `06-prepare-flux.sh` | Fills kfleet `clusters/sandbox2-azure` with the real workload-identity client IDs and the OIDC issuer, grants AcrPull on the shared `tsravaultdev` registry, and seeds the Key Vault secrets Terraform doesn't create (TLS cert, plus `SOURCE_KV` copies of the manual MCP / langfuse / victoriametrics secrets) |
| 7 | Tessera admin | `07-flux-bootstrap.sh` | "Bootstrap Flux": copies the signed kfleet artifact JFrog → ACR, then runs the kfleet `bootstrap-*-azure` steps through `az aks command invoke`, because the cluster is private |
| 5 | Both | `05-teardown.sh` | `terraform destroy` as the SPN, then admin cleanup. Run it last. |

## Prerequisites

- `az` CLI logged in as an admin of the target subscription. The admin
  needs User Access Administrator or Owner to create the role definitions
  and assignments, plus permission to create an Entra app registration.
- Terraform ≥ 1.12. You also need git access to the private
  `Tessera-Labs-Inc/terraform-azure-modules-*` repos over HTTPS
  (`gh auth setup-git` or a credential helper).
- `python3`.

Defaults are in `env.sh`. Override any of them with environment variables,
for example `SUB_ID=... LOCATION=westus2 ./01-customer-prereqs.sh`. The
defaults are:

- **Subscription:** `dev` (`b5835a01-…`).
- **Hub:** simulated by a separate hub resource group in the same
  subscription.
- **Location:** `eastus2`.
- **Module:** orchestration-final `v0.10.2`.

For the isolated credential-store test, export `CREDENTIAL_STORE_TEST=true` before
running the steps. It defaults to a separate `vaulttest-temp` environment and
pins orchestration-final `v0.11.1`. The module creates a private credential
vault with a vault-scoped Backend grant. Foundry release stays off.

Credentials, rendered Terraform, and logs go to `~/.tessera-azure-temp/<name>/`
(mode 700), never into the repo.

## Run it

```bash
cd tessera-checklist
source tests/azure-temp-deployment/env.sh

tests/azure-temp-deployment/01-customer-prereqs.sh      # ~10 min
tests/azure-temp-deployment/02-create-roles-and-spn.sh  # ~1 min, then wait ~5 min for RBAC propagation
tests/azure-temp-deployment/03-verify.sh                # must pass before step 4
tests/azure-temp-deployment/04-terraform-apply.sh plan  # optional dry run
ADMIN_OID=$(az ad signed-in-user show --query id -o tsv) \
  tests/azure-temp-deployment/04-terraform-apply.sh       # ~30-45 min; ADMIN_OID = AKS + KV admin for steps 6-7

# Flux (kfleet clusters/sandbox2-azure, cloned from sandbox-internal-azure)
KFLEET_DIR=~/platform-deployment/kfleet SOURCE_KV=private-sandbox-kv \
  tests/azure-temp-deployment/06-prepare-flux.sh
#   -> commit kfleet clusters/sandbox2-azure, merge to kfleet main (push-artifact signs + publishes to JFrog)
KFLEET_DIR=~/platform-deployment/kfleet tests/azure-temp-deployment/07-flux-bootstrap.sh
```

For the credential-store variant, run steps 1, 4, 6, and 7 with
`CREDENTIAL_STORE_TEST=true`. Skip steps 2 and 3. Platform must use an admin
Azure CLI session for step 4 because the module creates and assigns a custom
vault role. The role-test service principal deliberately lacks that authority.
Step 1 grants the admin data access to the test's Terraform state account.
Use the `kfleet` `sandbox2-azure` draft. Don't copy secrets from another vault
into this synthetic test environment.

```bash
export CREDENTIAL_STORE_TEST=true
tests/azure-temp-deployment/01-customer-prereqs.sh
tests/azure-temp-deployment/04-terraform-apply.sh plan
tests/azure-temp-deployment/04-terraform-apply.sh
KFLEET_DIR=~/platform-deployment/kfleet SOURCE_KV= tests/azure-temp-deployment/06-prepare-flux.sh
# Review and merge the filled kfleet draft before bootstrap.
KFLEET_DIR=~/platform-deployment/kfleet ARTIFACT_SOURCE=jfrog tests/azure-temp-deployment/07-flux-bootstrap.sh
```

Step 6 fills the cluster's identity and vault placeholders. Step 7 copies its
signed artifact. Enable the deployment-wide policy only in this isolated
cluster, after the images and enrollment path are ready. Run step 5 from the
same admin session to tear it down.

In the role test, when step 4 fails on permissions,
`~/.tessera-azure-temp/<name>/authorization-failures.txt`
lists each missing action and the scope it was needed on. To fix one:

1. Add the action to the right `policies/azure/*.json` file.
2. Re-run `02-create-roles-and-spn.sh`. It updates existing role
   definitions in place.
3. Wait a few minutes for propagation, then re-run step 4. Terraform picks
   up where it stopped.

Tear down when you're finished. The test environment costs roughly
$1.5–2.5/hour while it's up: 5 small AKS nodes, the jumpbox, the NAT VM,
burstable PostgreSQL, and Managed Redis B0.

```bash
tests/azure-temp-deployment/05-teardown.sh                    # keeps the custom role definitions
DELETE_ROLES=true tests/azure-temp-deployment/05-teardown.sh  # also deletes them
```

## Deliberate differences from a customer deployment

- **Hub peering is created by the customer script, and Terraform runs with
  `enable_hub_peering = false`.** The networking module (v0.4.0) sets
  `use_remote_gateways = true` on the spoke→hub peering. That requires a
  VPN/ExpressRoute gateway in the hub, and this test hub doesn't have one.
  As a result, the hub role's peering actions aren't exercised here; its
  Private DNS actions are.
- **The hub firewall is a NAT VM** (IP forwarding plus iptables MASQUERADE)
  at `HUB_FIREWALL_IP`. The module's route tables send `0.0.0.0/0` there
  exactly as they would to an Azure Firewall.
- **Key Vault public network access is on, allow-listed to the runner's
  public IP.** Terraform writes secrets through the Key Vault data plane. A
  customer's self-hosted Azure DevOps agent reaches the vault through its
  subnet and the private endpoint instead.
- **Hub Private DNS zones are linked to the spoke VNet as well as the hub.**
  The checklist instead relies on custom DNS conditional forwarders.
- **Small SKUs everywhere.** The GPU pool keeps `Standard_NC4as_T4_v3`
  (the module only accepts N-series) at 0 nodes, so it needs no GPU quota. `encryption_at_host_enabled = false` because the `EncryptionAtHost`
  feature isn't registered in `dev`.
- **Managed Redis region (`REDIS_LOCATION`, test only).** The `dev`
  subscription can't create Azure Managed Redis in East US 2 at any SKU
  ("…is not supported for your subscription in East US 2"). Setting
  `REDIS_LOCATION=eastus` makes step 4 use a local copy of orchestration-final
  in which only the `azurerm_managed_redis` resource moves to that region. It's
  reached through its private endpoint in the VNet's region, so nothing
  permission-related changes. Customer subscriptions don't need this.
- **Resizing an existing node pool.** Changing `vm_size` in place needs
  `temporary_name_for_rotation`, which the AKS wrapper doesn't pass to user
  pools. Run `terraform taint` on the pool first. The pools use
  `create_before_destroy` with randomized names, so the new size comes up
  before the old pool is removed.
- **The original role test stops at infrastructure.** The opt-in
  credential-store test continues through Flux, enrollment, and application
  acceptance in the isolated cluster.
