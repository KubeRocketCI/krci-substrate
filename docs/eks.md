# krci-substrate on Amazon EKS

What the AWS side and the cluster must provide before the chart installs on EKS. Sources: the chart `appVersion` (upstream `v1.0.1`) and `deploy-templates/`.

Placeholders:

| Placeholder | Value |
|---|---|
| `<partition>` | AWS partition: `aws`, `aws-cn`, `aws-us-gov` |
| `<account>` | AWS account ID |
| `<region>` | AWS Region of the cluster and the bucket |
| `<cluster>` | EKS cluster name |
| `<bucket>` | snapshot bucket, chart value `snapshots.s3.bucket` |
| `<prefix>` | key prefix, chart value `snapshots.s3.prefix` |
| `<keys>` | `<prefix>/atespaces/*`; empty prefix: `atespaces/*` |

## Snapshot bucket

- One bucket per cluster, for Substrate only. Both roles have `s3:ListBucket` on the whole bucket.
- Snapshot location: `s3://<bucket>/<prefix>/`; empty prefix: `s3://<bucket>/`. Objects: `<keys>`, that is `.../atespaces/<atespace>/actors/...` and `.../atespaces/<atespace>/tags/...`.
- Region: the cluster Region. Chart value `snapshots.s3.region`.
- Block Public Access: on.
- Lifecycle rule `AbortIncompleteMultipartUpload`: 1 day.
- No expiration rule on `<keys>`. ate-api-server deletes snapshots that nothing refers to.
- Versioning: off. On: add a `NoncurrentVersionExpiration` rule.
- SSE-S3: no extra permission. SSE-KMS with a customer managed key: add `kms:GenerateDataKey` and `kms:Decrypt` on the key to both permissions policies.

## IAM

Two roles, one per ServiceAccount. Each pod uses its own credentials.

| Role (example name) | ServiceAccount | S3 calls (upstream `objectstore-plugin`) |
|---|---|---|
| `<cluster>-substrate-api-server` | `ate-system/ate-api-server` | `control` mode: ListObjectsV2, HeadObject, CopyObject, CreateMultipartUpload, UploadPartCopy, CompleteMultipartUpload, AbortMultipartUpload, DeleteObject |
| `<cluster>-substrate-atelet` | `ate-system/atelet` | `node` mode: GetObject (ranged), PutObject, CreateMultipartUpload, UploadPart (32 MiB parts), CompleteMultipartUpload, AbortMultipartUpload |

`s3:ListBucket` on the bucket, no condition, both roles: without it, S3 answers `403 AccessDenied` for a missing object, not `404 NotFound`. atelet then fails where upstream expects `NotFound` (missing snapshot manifest). A condition on `s3:prefix` does not apply to GetObject and HeadObject.

### Trust policy

Both roles. Principal `pods.eks.amazonaws.com`: EKS Pod Identity. Conditions: the cluster only.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EksPodIdentity",
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"],
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "<account>" },
        "ArnEquals": { "aws:SourceArn": "arn:<partition>:eks:<region>:<account>:cluster/<cluster>" }
      }
    }
  ]
}
```

### Permissions policy: ate-api-server

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Bucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:<partition>:s3:::<bucket>"
    },
    {
      "Sid": "Snapshots",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:<partition>:s3:::<bucket>/<keys>"
    }
  ]
}
```

| Action | S3 calls |
|---|---|
| `s3:ListBucket` | ListObjectsV2; `404` for a missing object |
| `s3:GetObject` | HeadObject; source of CopyObject and UploadPartCopy |
| `s3:PutObject` | CopyObject, CreateMultipartUpload, UploadPartCopy, CompleteMultipartUpload |
| `s3:DeleteObject` | DeleteObject |
| `s3:AbortMultipartUpload` | AbortMultipartUpload |

### Permissions policy: atelet

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Bucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:<partition>:s3:::<bucket>"
    },
    {
      "Sid": "Snapshots",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:<partition>:s3:::<bucket>/<keys>"
    }
  ]
}
```

| Action | S3 calls |
|---|---|
| `s3:ListBucket` | `404` for a missing object |
| `s3:GetObject` | GetObject |
| `s3:PutObject` | PutObject, CreateMultipartUpload, UploadPart, CompleteMultipartUpload |
| `s3:AbortMultipartUpload` | AbortMultipartUpload |

SandboxConfig asset URLs on `s3://`: add `s3:GetObject` on those objects to the atelet policy. Chart default: none (`gvisor-default` uses `gs://gvisor`, read anonymously).

## Pod Identity associations

| Namespace | ServiceAccount | Role |
|---|---|---|
| `ate-system` | `ate-api-server` | `<cluster>-substrate-api-server` |
| `ate-system` | `atelet` | `<cluster>-substrate-atelet` |

- Create the associations before the chart install. The ServiceAccounts can come later: the chart creates them.
- A pod gets credentials only when it starts after its association. A pod that started before: `kubectl -n ate-system rollout restart deployment/ate-api-server daemonset/atelet`.
- Chart values: `apiServer.serviceAccount.annotations` and `atelet.serviceAccount.annotations` stay `{}`; `snapshots.s3.credentialsSecret` stays empty. The `objectstore-plugin` sidecars use the AWS SDK default credential chain.

### Terraform

```hcl
variable "cluster_name" {
  type = string
}

variable "bucket" {
  description = "Chart value snapshots.s3.bucket."
  type        = string
}

variable "prefix" {
  description = "Chart value snapshots.s3.prefix. No leading or trailing slash. Empty: no prefix."
  type        = string
  default     = ""
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  partition   = data.aws_partition.current.partition
  account_id  = data.aws_caller_identity.current.account_id
  bucket_arn  = "arn:${local.partition}:s3:::${var.bucket}"
  keys_arn    = "${local.bucket_arn}/${var.prefix == "" ? "" : "${var.prefix}/"}atespaces/*"
  cluster_arn = "arn:${local.partition}:eks:${data.aws_region.current.region}:${local.account_id}:cluster/${var.cluster_name}"

  substrate_roles = {
    api-server = {
      service_account = "ate-api-server"
      object_actions  = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
    }
    atelet = {
      service_account = "atelet"
      object_actions  = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
    }
  }
}

data "aws_iam_policy_document" "substrate_trust" {
  statement {
    sid     = "EksPodIdentity"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.cluster_arn]
    }
  }
}

data "aws_iam_policy_document" "substrate" {
  for_each = local.substrate_roles
  statement {
    sid       = "Bucket"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }
  statement {
    sid       = "Snapshots"
    actions   = each.value.object_actions
    resources = [local.keys_arn]
  }
}

resource "aws_iam_role" "substrate" {
  for_each           = local.substrate_roles
  name               = "${var.cluster_name}-substrate-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.substrate_trust.json
}

resource "aws_iam_role_policy" "substrate" {
  for_each = local.substrate_roles
  name     = "snapshots"
  role     = aws_iam_role.substrate[each.key].id
  policy   = data.aws_iam_policy_document.substrate[each.key].json
}

resource "aws_eks_pod_identity_association" "substrate" {
  for_each        = local.substrate_roles
  cluster_name    = var.cluster_name
  namespace       = "ate-system"
  service_account = each.value.service_account
  role_arn        = aws_iam_role.substrate[each.key].arn
}
```

Provider: AWS provider 6.x (`data.aws_region.current.region`; 5.x: `.name`). The provider Region is the cluster Region.

### IRSA

In place of Pod Identity. Same permissions policies. Trust policy: `sts:AssumeRoleWithWebIdentity` for the cluster OIDC provider, `sub` = `system:serviceaccount:ate-system:ate-api-server` and `system:serviceaccount:ate-system:atelet`. Chart values: `eks.amazonaws.com/role-arn: <role ARN>` in `apiServer.serviceAccount.annotations` and `atelet.serviceAccount.annotations`.

## Preflight

Run against the target cluster before the first sync. Output other than the expected output: do not install.

### 1. Certificate APIs

```bash
kubectl api-resources --api-group=certificates.k8s.io
```

Expected: rows `clustertrustbundles` and `podcertificaterequests`, API version `certificates.k8s.io/v1` or `certificates.k8s.io/v1beta1`:

```text
NAME                         SHORTNAMES   APIVERSION               NAMESPACED   KIND
certificatesigningrequests   csr          certificates.k8s.io/v1   false        CertificateSigningRequest
clustertrustbundles                       certificates.k8s.io/v1   false        ClusterTrustBundle
podcertificaterequests                    certificates.k8s.io/v1   true         PodCertificateRequest
```

Only `certificatesigningrequests`: the Kubernetes version does not serve the pod certificate APIs. EKS has no setting for kube-apiserver API groups or feature gates: upgrade the cluster. Without the APIs, podcertificate-controller fails with `neither v1 nor v1beta1 PodCertificateRequest is served`, and no Substrate pod starts.

### 2. EKS Pod Identity agent

```bash
aws eks describe-addon --cluster-name <cluster> --addon-name eks-pod-identity-agent --query addon.status --output text
kubectl -n kube-system rollout status daemonset/eks-pod-identity-agent --timeout=60s
```

Expected:

```text
ACTIVE
daemon set "eks-pod-identity-agent" successfully rolled out
```

`ResourceNotFoundException` or `daemonsets.apps "eks-pod-identity-agent" not found`: install the add-on `eks-pod-identity-agent`.

### 3. VPC CNI network policy

The `ate-system` NetworkPolicies need enforcement. Without it, every pod in the cluster reaches PostgreSQL, atelet and ate-api-server.

```bash
kubectl -n kube-system get daemonset aws-node \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-eks-nodeagent")].args}{"\n"}'
```

Expected: the list contains `--enable-network-policy=true`.

`--enable-network-policy=false`: set `enableNetworkPolicy: "true"` in the configuration values of the add-on `vpc-cni`. This enforces the NetworkPolicies of all other workloads too: check them first.

### 4. OIDC issuer

```bash
aws eks describe-cluster --name <cluster> --query cluster.identity.oidc.issuer --output text
kubectl get --raw /.well-known/openid-configuration | jq -r .issuer
```

Expected: the same URL twice, `https://oidc.eks.<region>.amazonaws.com/id/<ID>`. Chart value `apiServer.serviceAccountIssuer`: this URL, exact match.

### 5. cert-manager and External Secrets Operator

```bash
kubectl api-versions | grep -xE 'cert-manager.io/v1|external-secrets.io/v1'
```

Expected:

```text
cert-manager.io/v1
external-secrets.io/v1
```

### 6. PostgreSQL volume

```bash
kubectl get storageclass
```

Expected: one StorageClass marked `(default)`, provisioner `ebs.csi.aws.com` or another `ReadWriteOnce` provisioner. None: set `postgres.storage.storageClassName`. Claim size: `postgres.storage.size`, default 500Gi.

### 7. Egress

`<gvisor-url>`: an asset `url` of SandboxConfig `gvisor-default` (`deploy-templates/templates/sandboxconfig/gvisor.yaml`), `gs://` replaced by `https://storage.googleapis.com/`. One per node architecture.

```bash
kubectl run substrate-egress-check --rm -i --restart=Never --image=curlimages/curl -- sh -c '
  curl -sSI -o /dev/null -w "gvisor %{http_code}\n" <gvisor-url>
  curl -sS -o /dev/null -w "issuer %{http_code}\n" <issuer>/.well-known/openid-configuration
  curl -sS -o /dev/null -w "s3 %{http_code}\n" https://s3.<region>.amazonaws.com/'
```

Expected: `gvisor 200`, `issuer 200`, `s3` with any HTTP status. A timeout or a resolve error: open the egress in [Egress](#egress).

## Egress

The chart NetworkPolicies limit ingress only. The VPC security groups, NAT and egress proxies must allow:

| Source | Destination | Port | Use |
|---|---|---|---|
| atelet | `storage.googleapis.com` | 443 | gVisor assets of SandboxConfig `gvisor-default` (`gs://gvisor`), anonymous |
| ate-api-server | issuer host of `apiServer.serviceAccountIssuer`, `oidc.eks.<region>.amazonaws.com` | 443 | OIDC discovery and keys, ServiceAccount token verification |
| ate-api-server, atelet | `s3.<region>.amazonaws.com`, `<bucket>.s3.<region>.amazonaws.com` | 443 | snapshots; or an S3 gateway VPC endpoint |
| EKS Pod Identity agent (node) | `eks-auth.<region>.api.aws` | 443 | AssumeRoleForPodIdentity; or an `eks-auth` interface VPC endpoint |
| nodes | `ghcr.io`, `pkg-containers.githubusercontent.com` | 443 | images `ghcr.io/agent-substrate/substrate/*` |
| nodes | `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` | 443 | image `postgres` |

Actor egress: through atenet-egress, to the destinations of each actor's EgressPolicy.

## Chart values

```yaml
snapshots:
  s3:
    bucket: <bucket>
    region: <region>
    prefix: <prefix>
apiServer:
  serviceAccountIssuer: https://oidc.eks.<region>.amazonaws.com/id/<ID>
atelet:
  imageCredentialProvider:
    # EKS AMIs (Amazon Linux 2023): the kubelet ECR credential provider.
    binDir: /etc/eks/image-credential-provider
    config: /etc/eks/image-credential-provider/config.json
router:
  # kubectl ate proxy actor. Add the SPIFFE IDs of other clients.
  ingressAllowedSpiffeIds:
    - spiffe://cluster.local/ns/ate-system/sa/atenet-client
```

## After the install

```bash
kubectl -n ate-system logs deployment/ate-api-server -c objectstore-plugin | grep -m1 'Using S3 storage backend'
kubectl -n ate-system get configmap ate-api-server-envvars -o jsonpath='{.data.ATE_API_SNAPSHOT_LOCATION}{"\n"}'
```

Expected: a log line `Using S3 storage backend`; `s3://<bucket>/<prefix>/`.

- S3 access of both roles: a golden snapshot (ate-api-server copies it to a tag) and a suspended actor (atelet uploads it). The kind smoke test `e2e/chainsaw/02-actor` does both. It lists objects through the RustFS fixture: it does not run on EKS as is.
- `AccessDenied` in the `objectstore-plugin` logs of `deployment/ate-api-server` or `daemonset/atelet`: check the association, the trust policy conditions and `<keys>`.
