# Tessera AWS Deployment Policy

These three IAM policy documents, attached together to a single role, are
what Terraform uses to stand up and manage a full Tessera environment on
AWS. A customer creates the role (trust policy: the GitHub Actions
self-hosted runner, or OIDC federation if the runner assumes a role via
`sts:AssumeRoleWithWebIdentity`), attaches all three policies to it, and
that role ARN is what goes wherever the onboarding checklist asks for the
"IAM principal for initial deploy." Together they replace granting
`AdministratorAccess` to that role.

- `tessera-deployment-policy-01-networking-compute.json` — VPC networking,
  EC2 compute, Auto Scaling, EKS, container registry (ECR)
- `tessera-deployment-policy-02-data-dns-logs.json` — RDS, ElastiCache,
  Secrets Manager, S3, Route 53, CloudWatch Logs
- `tessera-deployment-policy-03-identity-security.json` — IAM, KMS, STS,
  Bedrock, and the guardrail deny statements

## Why three files, and no wildcard actions

Every `Action` is a fully-qualified action name — no `service:*` and no
`service:Verb*` wildcards. A blanket wildcard is exactly what a customer
security review pushes back on, so every permission this role has is
enumerated individually. That comes at a real size cost: AWS caps a single
customer-managed policy at 6,144 characters of policy document, and the
full action list across this many services doesn't fit in one file. The
split follows the natural boundary in the architecture — networking and
compute, data and supporting services, identity and security — which also
keeps each file readable on its own during a review instead of being one
undifferentiated wall of actions. A role can hold up to 20 managed
policies, so attaching three is unremarkable.

## The architecture, and why the deploy role needs each piece

A Tessera environment is a VPC-hosted EKS cluster with its supporting data
services, a container registry, and a set of per-workload IAM roles that
let pods talk to AWS directly instead of through node-level credentials.
Terraform owns the full lifecycle of nearly all of this — create it,
detect drift on every plan, update it, and tear it down if the environment
is decommissioned — which is why the actions below span create, describe,
modify, delete, and tag for each resource type rather than just create.

### Networking

Terraform places the environment inside an existing customer VPC: subnets,
route tables, a NAT Gateway with its Elastic IP, security groups and their
rules, and VPC endpoints for private access to S3/ECR/STS from inside the
cluster. VPC Flow Logs ship network traffic metadata to CloudWatch Logs.

- Create/modify/delete on VPCs, subnets, route tables, the internet
  gateway, NAT gateway, Elastic IPs, security groups and their rules, VPC
  endpoints, and flow logs — this is Terraform owning the full lifecycle
  of each.
- Describe/list equivalents for every one of the above — Terraform
  re-resolves the current state of every resource it manages on every
  `plan`, whether or not anything changed.
- `ec2:ImportKeyPair` / `DeleteKeyPair` (no `CreateKeyPair`) — SSH access
  uses a customer-provided public key, imported rather than generated.
  Nothing in this policy can mint a brand-new private key.
- Transit Gateway attachment actions — only relevant for a customer whose
  network already has a hub-and-spoke Transit Gateway topology; unused
  when the VPC connects out through a plain internet gateway/NAT instead.
- `ec2:CreateVpc` / `DeleteVpc` / `CreateInternetGateway` /
  `DeleteInternetGateway` are granted here but blocked by a guardrail deny
  further down, since standard onboarding assumes the customer already has
  a VPC and internet gateway. An account that wants Terraform to build the
  network from scratch needs that guardrail relaxed first.

### Compute and Auto Scaling

EKS managed node groups run on top of plain EC2 Auto Scaling Groups, so the
node fleet's actual lifecycle — launching, scaling, replacing instances —
goes through the Auto Scaling and EC2 launch-template APIs, not through EKS
directly.

- Launch templates (create/version/modify/delete) define each node group's
  instance type, AMI, and boot configuration; a new template version gets
  created whenever that configuration changes.
- `ssm:GetParameter`, scoped to AWS's own public
  `/aws/service/eks/...` parameter path — resolves the current
  EKS-optimized AMI ID instead of hardcoding one. This is the only SSM
  permission in the whole policy, and it can only ever read AWS-published
  values, never a customer's own parameters.
- Auto Scaling Group create/update/delete, describe, and lifecycle hooks
  back the node group's actual capacity management — EKS asks Auto Scaling
  to do the scaling, so the deploy role needs to be able to create and
  manage the ASG resources themselves.
- `ec2:RunInstances` and the instance lifecycle actions (terminate, stop,
  start, monitor) cover the underlying EC2 instances a managed node group's
  Auto Scaling Group launches, plus manual instance operations if a node
  ever needs to be replaced by hand.

### EKS

The control plane, its managed node groups, core addons, and the two
mechanisms that grant identity to things running inside the cluster.

- Cluster and node group create/update/delete/describe — the control
  plane and the compute it schedules onto.
- Addon management (create/update/delete/describe) — the EKS-managed
  addons every cluster runs: VPC CNI, CoreDNS, kube-proxy, the EBS CSI
  driver, and the Pod Identity Agent.
- Access entries map an IAM principal to Kubernetes RBAC permissions —
  this is how cluster-admin access gets granted without hand-editing
  `aws-auth`.
- Pod Identity associations bind a Kubernetes service account to an IAM
  role, one per workload — every pod-identity-backed service in the
  cluster (the auth service, backend API, data pipeline, frontend,
  model-serving layer, vector search, GitOps controller, autoscaler, the
  storage CSI driver, DNS sync, secrets sync, observability agents,
  database monitoring, and so on) gets its own association, so a typical
  environment has several dozen of these.
- `eks:AssociateEncryptionConfig` turns on KMS envelope encryption for
  Kubernetes Secrets at the API server level.

### Container registry (ECR)

Two different things happen against ECR: managing the repositories
themselves, and the actual `docker push`/`docker pull` traffic every CI
image build generates.

- Repository lifecycle: create/delete a repo, its lifecycle policy, image
  scanning configuration, and tag-mutability setting.
- Image data plane: the full layer-upload sequence
  (`InitiateLayerUpload` → `UploadLayerPart` → `CompleteLayerUpload`,
  gated by `BatchCheckLayerAvailability`), `PutImage` to register a
  manifest, and `BatchGetImage` / `GetDownloadUrlForLayer` /
  `ListImages` / `BatchDeleteImage` for pulling and cleaning up images.
  Without this half of the statement, the repositories would exist but
  every image build in CI would fail outright.
- `ecr:GetAuthorizationToken` is its own statement because it's how
  `docker login` (or `aws ecr get-login-password`) authenticates before any
  push or pull can happen — it has no per-repository form, it's either
  granted or it isn't.

### Database (RDS)

A single PostgreSQL instance, its parameter group, and its subnet group.

- Create/modify/delete on the instance, parameter group, and subnet
  group — the three resources that make up the database layer.
- `rds:DescribeDBEngineVersions` / `DescribeOrderableDBInstanceOptions` —
  looked up when picking (or validating) which PostgreSQL engine version
  and instance class combination is available in the region.
- `rds:RestoreDBInstanceFromDBSnapshot` / `DescribeDBSnapshots` — restoring
  an instance from a snapshot is a first-class, directly configurable
  option (not a hidden edge case), used for environment-migration flows.

### Cache (ElastiCache)

A Redis replication group backing the application's caching layer, plus
its subnet and parameter groups — the same create/modify/delete/describe
pattern as RDS, one layer over.

### Secrets

Every secret Terraform writes: database credentials, TLS certificate
material, and application configuration secrets used by DNS and
model/tool-integration workloads.

- Create/read/update/delete on secrets and their values.
- `secretsmanager:GetResourcePolicy` and `UpdateSecretVersionStage` cover
  the resource-policy read and version-stage transition the Secrets
  Manager API performs alongside a normal secret write — not something
  Terraform calls directly by name, but part of how the provider manages a
  secret's lifecycle underneath the `aws_secretsmanager_secret` resource.
- `secretsmanager:ListSecrets` is a separate statement since it enumerates
  every secret in the account rather than one by name.
- `secretsmanager:RestoreSecret` covers recreating a secret of the same
  name shortly after it was deleted, while it's still inside its recovery
  window — a normal occurrence across a teardown/redeploy cycle.

### Storage (S3)

Buckets for application assets, access logs, and other environment
storage.

- Bucket create/delete plus the full configuration surface: public-access
  block, encryption, versioning, logging, tagging, CORS, lifecycle rules,
  object lock, bucket policy, replication, request-payer, and static
  website configuration. Terraform's S3 provider reads back every one of
  these sub-resources on every refresh regardless of whether a given
  bucket actually uses that feature, so the read side of this list is
  wider than what any single bucket configures.
- Object-level `GetObject`/`PutObject`/`DeleteObject` access is scoped to
  the case where the customer hosts the Terraform state bucket themselves
  rather than Tessera hosting it — the onboarding checklist lists the
  state bucket as either "Customer or Tessera."

### DNS (Route 53)

A private hosted zone for internal service discovery.

- Create/delete the zone, associate/disassociate it with VPCs, update its
  comment, and read it back for drift detection.
- `route53:ListResourceRecordSets` is specifically how Terraform reads the
  zone's own NS records to populate the zone resource's `name_servers`
  output — it is not general permission to read arbitrary DNS records.
  Application-level DNS records are created and updated at runtime by
  `external-dns`, running under its own pod-identity role, which is why
  `route53:ChangeResourceRecordSets` is deliberately not part of this
  policy.

### Logging (CloudWatch Logs)

Log groups for the EKS control plane, VPC Flow Logs, and the cache's slow
log — created once per environment and otherwise just read back for
retention/tag drift.

### Identity (IAM)

Every IAM role this deployment creates: the several dozen per-workload pod
identity roles described above, the EKS node group's instance-profile
role, and the RDS enhanced-monitoring role.

- Role, policy, and instance-profile create/read/update/delete, plus
  attaching a policy to a role and associating a role with an instance
  profile — the full set of operations needed to stand up a new IAM
  identity for a workload and wire it together.
- `iam:CreateOpenIDConnectProvider` and its sibling actions set up the
  OIDC trust GitHub Actions uses to authenticate as this role in the first
  place — a bootstrap-time operation.
- `iam:PassRole` is restricted by a condition to the specific AWS service
  principals Tessera's modules actually hand a role to: EC2, EKS, EKS
  Fargate, EKS node groups, EKS Pod Identity, RDS, RDS monitoring, and VPC
  Flow Logs. Without that condition, an unscoped PassRole would let this
  role hand any IAM role in the account to any AWS service — the condition
  is what keeps this from being a privilege-escalation path.
- `iam:CreateServiceLinkedRole` is similarly restricted to the specific
  AWS service names (`eks`, `eks-nodegroup`, `rds`, `elasticache`,
  `autoscaling`, `spot`, `spotfleet`) whose first use in an account
  triggers AWS to create one automatically.

### Encryption (KMS)

- One statement, conditioned on the key carrying the tag every
  Terraform-managed resource in this account gets (`ManagedBy=terraform`),
  covers managing keys Terraform already created — the EKS cluster's
  Kubernetes Secrets envelope-encryption key today, and any other
  Terraform-managed key going forward. The tag condition means this role
  can act on Terraform's own keys and nothing else.
- `kms:CreateKey` is its own statement because a key that doesn't exist
  yet has no ARN and no tag to condition on.

### Caller identity (STS)

`sts:GetCallerIdentity` — every module that needs the current account ID
in an ARN gets it from the `aws_caller_identity` data source, which every
`plan` re-evaluates.

### Model inference (Bedrock)

`bedrock:InvokeModel` and the model-discovery actions support environments
where the model-serving/orchestration layer is configured to call
Bedrock-hosted foundation models. An environment that points its
model-serving layer at a different provider instead simply doesn't
exercise this part of the policy — the permissions stay in place because
they're part of the standard module composition, not something toggled
per customer.

## Guardrails

Six deny statements sit in file 03 as a hard backstop, independent of
whatever the allow statements above grant:

- **No IAM users or long-lived credentials.** This role only ever manages
  roles for workloads — it can't create an IAM user, an access key, a
  login profile, or a group, and can't attach policies to one.
- **No building network primitives from scratch, no ad-hoc SSH keys.**
  `ec2:CreateVpc` / `DeleteVpc` / `CreateInternetGateway` /
  `DeleteInternetGateway` / `CreateKeyPair` are blocked by default, since
  onboarding assumes an existing customer VPC and an imported SSH key. An
  account that wants Terraform to build the VPC/IGW needs this relaxed
  first.
- **No public RDS.** `rds:CreateDBInstance` / `ModifyDBInstance` /
  `CreateDBCluster` / `ModifyDBCluster` are denied outright — the intent is
  to force RDS changes through a separate, narrower path if a
  publicly-accessible database is ever genuinely needed, rather than let a
  stray Terraform change flip that flag.
- **No disabling security telemetry.** CloudTrail, Config, GuardDuty, and
  Security Hub can't be stopped, deleted, or reconfigured by this role.
- **No making S3 public.** Account-level and bucket-level public-access
  controls can't be loosened, and bucket policies can't be deleted, by
  this role.
- **No organization or account-wide changes.** This role can't leave or
  modify the AWS Organization, close the account, or change
  account-wide contact/region settings.

## Practical notes

- **Transit Gateway support** is included for customers whose network
  already routes through a hub-and-spoke Transit Gateway rather than a
  plain internet gateway/NAT setup — an environment that doesn't use TGW
  simply never exercises those five actions.
- **Bedrock support** is part of the standard module composition but only
  matters for an environment whose model-serving layer is actually
  configured to call Bedrock.
- **S3 state-backend object access** only matters when the customer hosts
  the Terraform state bucket themselves; when Tessera hosts state instead,
  this role never touches it.
- **The GitHub Actions OIDC provider** isn't provisioned by any Terraform
  module today — it's set up by hand during onboarding. The
  `iam:*OpenIDConnectProvider*` actions are here for if/when that becomes
  Terraform-managed.
- **If a customer account has no existing VPC or IGW** and wants Terraform
  to create them, drop `ec2:CreateVpc` / `ec2:CreateInternetGateway` from
  `DenyBootstrapOnlyNetworkPrimitives` for that account specifically.

## Usage

1. Create an IAM role in the customer's AWS account (trust policy: the
   GitHub Actions self-hosted runner's instance profile, or OIDC federation
   if the runner assumes a role via `sts:AssumeRoleWithWebIdentity`).
2. Attach all three `tessera-deployment-policy-0*.json` files as
   customer-managed policies on that role.
3. Use the resulting role ARN wherever the onboarding checklist calls for
   the "IAM principal with AdministratorAccess for initial deploy" — these
   policies are the replacement for that AdministratorAccess grant.

Azure and GCP equivalents follow the same per-service breakdown and live
alongside this one under `policies/azure/` and `policies/gcp/`
respectively.
