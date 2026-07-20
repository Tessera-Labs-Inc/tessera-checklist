# Tessera AWS Deployment Policy

Three IAM policy documents a customer attaches (all three, to the same role)
to the role used by Terraform (the GitHub Actions self-hosted runner instance
profile, per the onboarding checklist's "IAM principal ... for initial
deploy") to stand up a full Tessera environment on AWS. Together they replace
granting `AdministratorAccess` for that role.

- `tessera-deployment-policy-01-networking-compute.json` — EC2/VPC
  networking, Auto Scaling (EKS managed node groups), EKS, ECR
- `tessera-deployment-policy-02-data-dns-logs.json` — RDS, ElastiCache, Secrets
  Manager, S3, Route53, CloudWatch Logs
- `tessera-deployment-policy-03-identity-security.json` — IAM, KMS, STS,
  Bedrock, and all guardrail `Deny` statements

## Why three files, and no wildcards

Every `Action` is a fully-qualified, explicit action name — no `service:*`
and no `service:Verb*` suffix wildcards anywhere, since a blanket wildcard is
exactly what a customer security review will reject. That comes at a real
size cost: AWS caps a single customer-managed policy at **6,144 characters**
(non-whitespace) of policy document, and enumerating every action a dozen
Terraform modules actually call for 14 services doesn't fit in one. Splitting
along infra / data / identity lines keeps each file well under the limit
(current sizes: 4,446 / 3,023 / 4,662 chars) while keeping related actions
together for review. Attach all three to the role — IAM lets you attach up to
20 managed policies per role, so this is a normal pattern for a broad
deploy role.

## How the action lists were derived

Same repo-by-repo resource audit as before (see git history of this file for
the full per-repo breakdown), but this time each `resource "aws_*"` block was
mapped to the **exact AWS API actions** Terraform calls to create/read/
update/delete it — not just the service it belongs to. For example:
`aws_db_instance` → `rds:CreateDBInstance`, `rds:ModifyDBInstance`,
`rds:DeleteDBInstance`, `rds:DescribeDBInstances`, plus the parameter/subnet
group and tagging calls it also needs; `aws_eks_pod_identity_association` →
the `eks:*PodIdentityAssociation` family, not blanket `eks:*`.

Two things worth calling out explicitly:

- **`elasticloadbalancing` and `cloudwatch` (metrics/alarms) were dropped
  entirely**, even though the earlier wildcard-based version included them.
  No repo declares an `aws_lb`, `aws_elb`, `aws_lb_target_group`, or
  `aws_cloudwatch_metric_alarm` resource anywhere — Classic ELBs get
  provisioned by Kubernetes at runtime (via the node IAM role or a
  load-balancer-controller pod-identity role), not by Terraform. Keeping
  those permissions on the *deploy* role would be padding, not requirement.
  `cloudwatch` here specifically means the Alarms/Dashboards/Metrics
  namespace — CloudWatch **Logs** (a different action prefix, `logs:`) is
  still included since EKS control-plane logging, VPC flow logs, and the
  Redis slow-log all create `aws_cloudwatch_log_group` resources.
- **`iam:PassRole` and `iam:CreateServiceLinkedRole` are scoped with
  `Condition` blocks**, not left as bare `Resource: "*"` grants — PassRole is
  restricted to `iam:PassedToService` being one of the AWS service principals
  Tessera's modules actually pass roles to (EC2, EKS, EKS node groups, EKS
  pod identity, RDS + its monitoring role, VPC Flow Logs), and
  CreateServiceLinkedRole is restricted to the five AWS service names
  (`eks`, `eks-nodegroup`, `rds`, `elasticache`, `autoscaling`, `spot`,
  `spotfleet`) whose first-time-in-account use triggers an automatic
  service-linked-role creation. This is the standard mitigation for handing
  out broad `iam:PassRole`/`iam:CreateServiceLinkedRole`, since without a
  condition either one is a privilege-escalation vector.
- **Fixed a bug from an earlier draft of this policy**: `s3:PutBucketAcl` and
  friends were correctly denied as a "don't make S3 public" guardrail, but at
  one point `s3:PutBucketPublicAccessBlock` (the action our own S3 module
  uses to *enable* the public-access block — i.e. the safe direction) had
  also ended up in that same `Deny` list. Since `Deny` always wins over
  `Allow` in IAM's evaluation, that would have broken every bucket creation
  outright. There's no IAM condition key that distinguishes "set the block to
  true" from "set it to false" for that specific API, so the fix is to allow
  `PutBucketPublicAccessBlock` unconditionally and rely on the ACL/policy
  denies (which are the actual mechanisms that make something public) as the
  real guardrail.
- Kept the same deviations from the original reference sample as before:
  `ec2:AllocateAddress`/`AssociateAddress` are allowed (NAT Gateway EIPs are
  a real, expected part of the IGW deployment model), `ec2:CreateVpc` /
  `ec2:CreateInternetGateway` / `ec2:CreateKeyPair` stay denied (existing
  VPC/IGW is a required customer input per the checklist; SSH keys are always
  imported, never generated).

## Known caveats

- **Static analysis, not a live capture.** This was derived by reading
  Terraform source across ~30 repos, not by running `terraform apply` against
  a real account with CloudTrail-based IAM Access Analyzer policy generation.
  It should be very close, but if a fresh customer deploy hits an
  `AccessDenied`, that's the fastest way to close any remaining gap: run the
  failing step once, generate a policy from the CloudTrail events, and diff
  it against these three files.
- **S3 state-backend access is included but may be unnecessary.** The
  sandbox environment's Terraform state currently lives in
  `tessera-internal-tfstate`, a bucket in Tessera's own AWS account — so a
  customer-account role wouldn't need `s3:GetObject`/`PutObject`/`DeleteObject`
  for that. They're included in `02-data-dns-logs.json` anyway since the
  checklist lists the state bucket as "Customer or Tessera," i.e. sometimes
  customer-hosted.
- **The VPC/IGW edge case from before still applies**: if a customer account
  has no existing VPC or IGW and expects Terraform to create them from
  scratch, `DenyBootstrapOnlyNetworkPrimitives` (in file 03) blocks it by
  design. Drop `ec2:CreateVpc`/`ec2:CreateInternetGateway` from that deny for
  that specific account if this ever changes.
- **GitHub Actions OIDC provider for cross-account ECR push** (checklist:
  "GitHub Actions OIDC trust + IAM role to push to ECR") isn't backed by a
  Terraform resource in any repo audited — it may be set up manually today.
  The IAM statement in file 03 still includes the
  `iam:*OpenIDConnectProvider*` actions needed if/when that gets
  Terraform-managed.

## Usage

1. Create an IAM role in the customer's AWS account (trust policy: the
   GitHub Actions self-hosted runner's instance profile, or OIDC federation
   if the runner assumes a role via `sts:AssumeRoleWithWebIdentity`).
2. Attach all three `tessera-deployment-policy-0*.json` files as
   customer-managed policies on that role.
3. Use the resulting role ARN wherever the checklist calls for the
   "IAM principal with AdministratorAccess for initial deploy" — these
   policies are the replacement for that AdministratorAccess grant.

Azure and GCP equivalents will follow the same per-repo, per-action
derivation and live alongside this one under `policies/azure/` and
`policies/gcp/` respectively.
