# Tessera AWS Deployment Policy

`tessera-deployment-policy.json` is the single IAM policy a customer attaches to
the role used by Terraform (the GitHub Actions self-hosted runner instance
profile, per the onboarding checklist's "IAM principal ... for initial deploy")
to stand up a full Tessera environment on AWS. It replaces the current practice
of granting `AdministratorAccess` for that role with a scoped, reviewable
alternative that still covers every resource Tessera's Terraform modules
create.

## How this was derived

Built by walking every AWS-related Tessera repo and enumerating the actual
`resource "aws_*"` blocks each one declares (including the modules pulled in
only via remote `source = "github.com/Tessera-Labs-Inc/..."` references, which
were cloned locally to inspect since they aren't vendored in-repo):

- `terraform-aws-modules-networking` — VPC, subnets, route tables, IGW, NAT
  Gateway + EIP, Transit Gateway attachment, VPC Flow Logs
- `terraform-aws-modules-security-groups` — security groups + rules
- `terraform-aws-modules-vpc-endpoints` — interface/gateway VPC endpoints
- `terraform-aws-modules-eks` (wraps registry module `terraform-aws-modules/eks/aws`) —
  EKS cluster, managed node groups, addons, access entries, cluster KMS key,
  CloudWatch log group, node/cluster IAM roles, EBS CSI + external-dns pod
  identity roles, Secrets Manager entries, cluster-autoscaler policy
- `terraform-aws-modules-eks-pod-identity` — per-service-account IAM roles +
  `aws_eks_pod_identity_association`
- `terraform-aws-modules-compute` — operator/bastion EC2 instance, imported
  EC2 key pair, instance profile
- `terraform-aws-modules-database` — RDS (Postgres) instances, parameter/subnet
  groups, ElastiCache (Redis) replication group, RDS monitoring IAM role,
  Secrets Manager entries
- `terraform-aws-modules-s3` — assets/milvus/logs buckets (versioning, SSE,
  access logging, public-access-block already enforced in the module itself)
- `terraform-aws-modules-route53` — hosted zone + additional VPC associations
- `terraform-aws-modules-bedrock`, `-mcp`, `-cert` — Secrets Manager entries
  for LLM/MCP/TLS config
- `terraform-aws-modules-flux` — GitHub-side only (deploy keys, repo files);
  no AWS resources, not reflected in this policy
- `terraform-aws-modules-cloudflare-networking` — security group + VPC
  endpoint associations (Cloudflare API side is out of scope for AWS IAM)
- `terraform-aws-deployment-tessera` / `terraform-aws-modules-orchestration-tessera` —
  wire the above together; no additional resource types
- `terraform-aws-modules-ecr`, `terraform-aws-modules-bootstrap-ecr` (and the
  `modules/ecr`, `modules/bootstrap-ecr` copies inside the legacy `terraform-aws`
  monorepo) — `aws_ecr_repository` + `aws_ecr_lifecycle_policy`, the actual
  "Bootstrap: Image Registry (ECR)" checklist step
- `terraform-aws-bootstrap` — thin wrapper, only calls the networking module
- legacy `terraform-aws` monorepo, `environments/bootstrap-customer-dev` — the
  VDI bootstrap flow: bastion + Windows desktop EC2 instances (public subnet,
  SSH/RDP security groups), a shared EC2 instance role/profile with
  `AmazonSSMManagedInstanceCore` attached, imported key pair
- `terraform-aws-modules-orchestration-micron`, `-mdt`, and the local
  `-orchestration-merck` — customer-specific orchestrations; same module set
  as `-orchestration-tessera` (bedrock, cert, compute, database, eks(-pod-identity),
  networking, route53, s3, security-groups, vpc-endpoints) at different pinned
  versions, plus `aws_network_interface_sg_attachment` for desktop/bastion ENIs.
  No new services beyond what's already covered.
- `terraform-aws-modules-orchestration-vault`, `terraform-aws-modules-tessera` —
  unimplemented scaffolds (`resource "null_resource" "this" {}` only); nothing
  to account for yet
- `terraform-aws-internal` (Tessera's own AWS account — internal Vault +
  cross-region S3 replication) — explicitly out of scope, this manages
  Tessera-Labs-Inc's own infrastructure, not a customer's account
- `terraform-aws-legacy`, `terraform-aws-merck-mock`, `terraform-aws-merck-copy` —
  archived/mock/test repos, skipped as dead code

Confirmed via `gh`/GitHub search against the full `Tessera-Labs-Inc` org (32
`terraform-aws*` repos total) that this is the complete set of live repos —
not just the ones reachable from `terraform-aws-modules-orchestration-tessera`'s
module graph.

Given the number of distinct resource types (40+) spread across services,
this follows the same shape as the reference policy supplied: **broad
per-service `Allow` (`ec2:*`, `eks:*`, `rds:*`, ...) plus targeted `Deny`
guardrails**, rather than an unreadable per-action least-privilege list. A
true least-privilege policy would need to track every provider version bump
across a dozen module repos; the guardrails below are the actual security
boundary.

## Deviations from the reference policy sample

- **Removed `ec2:AllocateAddress` / `ec2:AssociateAddress` from the deny
  list.** `terraform-aws-modules-networking` allocates an EIP per AZ for its
  NAT Gateways whenever `enable_private_outbound = true` and no Transit
  Gateway is in play (the IGW model). Denying these actions breaks that path
  outright — confirmed by reading the module's `aws_eip.nat_az1`/`az2` and
  `aws_nat_gateway.az1`/`az2` resources. Kept `ec2:CreateVpc` /
  `ec2:CreateInternetGateway` denied instead, since those follow the intended
  flow (customer supplies an existing VPC ID and either a TGW or IGW ID per
  the checklist).
- **`ec2:CreateKeyPair` stays denied.** The compute module only ever imports
  the customer-supplied SSH public key (`aws_key_pair` with `public_key` set,
  i.e. `ec2:ImportKeyPair`), never generates one, so this denial is free.
- Added `s3:PutBucketPublicAccessBlock` to the "don't make S3 public" deny
  (the sample only covered `PutAccountPublicAccessBlock`, missing the
  per-bucket equivalent).
- Bedrock allow list adds `bedrock:GetFoundationModel` /
  `bedrock:ListFoundationModels` (read-only discovery) alongside the two
  `InvokeModel*` actions, so Terraform/operators can validate model
  availability without any Bedrock admin/write access.

## Known caveat / edge case not covered

If a customer account has **no existing VPC or IGW** and expects Tessera's
Terraform to create them from scratch (`existing_vpc_id` / IGW left unset),
the `DenyBootstrapOnlyNetworkPrimitives` statement will block that. Per the
checklist this isn't the expected path (an existing VPC ID + CIDR reservation
is a required customer input), but if that ever changes, drop
`ec2:CreateVpc` / `ec2:CreateInternetGateway` from the deny statement for that
account's policy.

## Usage

1. Create an IAM role in the customer's AWS account (trust policy: the
   GitHub Actions self-hosted runner's instance profile, or OIDC federation
   if the runner assumes a role via `sts:AssumeRoleWithWebIdentity`).
2. Attach `tessera-deployment-policy.json` as a customer-managed policy on
   that role.
3. Use the resulting role ARN wherever the checklist calls for the
   "IAM principal with AdministratorAccess for initial deploy" — this policy
   is the replacement for that AdministratorAccess grant.

Azure and GCP equivalents will follow the same per-repo derivation and live
alongside this one under `policies/azure/` and `policies/gcp/` respectively.
