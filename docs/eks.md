# krci-substrate on Amazon EKS

What the AWS side and the cluster must provide before the chart installs on EKS, and how to check the install. Sources: upstream release `v1.0.1` and `deploy-templates/`.

Placeholders:

| Placeholder | Value |
|---|---|
| `<partition>` | AWS partition: `aws`, `aws-cn`, `aws-us-gov` |
| `<account>` | AWS account ID |
| `<region>` | AWS Region of the cluster and the bucket |
| `<cluster>` | EKS cluster name |
| `<ID>` | ID of the cluster OIDC issuer, `https://oidc.eks.<region>.amazonaws.com/id/<ID>` |
| `<bucket>` | snapshot bucket, chart value `snapshots.s3.bucket` |
| `<prefix>` | key prefix, chart value `snapshots.s3.prefix` |
| `<keys>` | `<prefix>/atespaces/*`; empty prefix: `atespaces/*` |
| `<images>` | ECR repository name prefix of private actor images, see [Actor images](#actor-images) |
| `<context>` | kubeconfig context of the cluster |

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

Private actor images in ECR: add the statements of [Actor images](#actor-images) to the atelet policy.

## Pod Identity associations

| Namespace | ServiceAccount | Role |
|---|---|---|
| `ate-system` | `ate-api-server` | `<cluster>-substrate-api-server` |
| `ate-system` | `atelet` | `<cluster>-substrate-atelet` |

- Create the associations before the chart install. The ServiceAccounts can come later: the chart creates them.
- A pod gets credentials only when it starts after its association. A pod that started before: `kubectl -n ate-system rollout restart deployment/ate-api-server daemonset/atelet`.
- Pod Identity sets `AWS_CONTAINER_CREDENTIALS_FULL_URI` and `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` in every container of the pod: the `objectstore-plugin` sidecars and the `atelet` container.
- Chart values: `apiServer.serviceAccount.annotations` and `atelet.serviceAccount.annotations` stay `{}`; `snapshots.s3.credentialsSecret` stays empty. The `objectstore-plugin` sidecars use the AWS SDK default credential chain.

### Terraform

Modules `terraform-aws-modules/s3-bucket/aws` and `terraform-aws-modules/eks-pod-identity/aws`. Module versions and the AWS provider:

| Module | Version | AWS provider |
|---|---|---|
| `eks-pod-identity` | `2.11.0` | `>= 6.28`, Terraform `>= 1.5.7` |
| `s3-bucket` | `5.10.0` | `>= 6.28` |
| `s3-bucket` | `5.11.0` / `5.12.0` / `5.13.0` and later | `>= 6.37` / `>= 6.39` / `>= 6.42` |

A module version that needs a newer provider than the lock file fails `terraform init` with `locked provider ... does not match configured version constraint`.

```hcl
terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28"
    }
  }
}

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

variable "actor_images_prefix" {
  description = "ECR repository name prefix of private actor images: atelet pulls repository/<prefix>/*. Empty: no ECR access."
  type        = string
  default     = ""
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  keys_arn   = "${module.snapshots_bucket.s3_bucket_arn}/${var.prefix == "" ? "" : "${var.prefix}/"}atespaces/*"

  ecr_pull_statements = var.actor_images_prefix == "" ? [] : [
    {
      sid       = "EcrAuthorizationToken"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    },
    {
      sid       = "EcrPullActorImages"
      actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      resources = ["arn:${local.partition}:ecr:${data.aws_region.current.region}:${local.account_id}:repository/${var.actor_images_prefix}/*"]
    },
  ]

  substrate_roles = {
    api-server = {
      service_account = "ate-api-server"
      object_actions  = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
      ecr_pull        = false
    }
    atelet = {
      service_account = "atelet"
      object_actions  = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
      ecr_pull        = true
    }
  }
}

# Module defaults: Block Public Access on, no versioning. S3 defaults: SSE-S3, BucketOwnerEnforced.
module "snapshots_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.10.0"

  bucket = var.bucket

  lifecycle_rule = [
    {
      id                                     = "abort-incomplete-multipart-upload"
      enabled                                = true
      abort_incomplete_multipart_upload_days = 1
    }
  ]

  attach_deny_insecure_transport_policy = true
}

module "substrate_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.11.0"

  for_each = local.substrate_roles

  name            = "${var.cluster_name}-substrate-${each.key}"
  use_name_prefix = false

  trust_policy_conditions = [
    {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    },
    {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [data.aws_eks_cluster.this.arn]
    },
  ]

  attach_custom_policy      = true
  custom_policy_description = "krci-substrate ate-system/${each.value.service_account}: snapshots in ${var.bucket}"
  policy_statements = concat([
    {
      sid       = "Bucket"
      actions   = ["s3:ListBucket"]
      resources = [module.snapshots_bucket.s3_bucket_arn]
    },
    {
      sid       = "Snapshots"
      actions   = each.value.object_actions
      resources = [local.keys_arn]
    },
  ], each.value.ecr_pull ? local.ecr_pull_statements : [])

  associations = {
    (each.value.service_account) = {
      cluster_name    = var.cluster_name
      namespace       = "ate-system"
      service_account = each.value.service_account
    }
  }
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name  = var.cluster_name
  addon_name    = "eks-pod-identity-agent"
  addon_version = "<agent version>"
}
```

- The provider Region is the cluster Region.
- Cluster managed by `terraform-aws-modules/eks/aws`: the agent goes into the module input `addons` (`eks-pod-identity-agent = { addon_version = "<agent version>" }`) in place of `aws_eks_addon`.
- Agent already on the cluster, outside the Terraform state: add an `import` block, `to = <agent resource address>`, `id = "<cluster>:eks-pod-identity-agent"`. The plan shows an import and, for another version, an update in place.
- Plan of a new install: bucket module 4 resources (bucket, public access block, lifecycle configuration, bucket policy), 5 with `logging`; per role 4 (role, policy, policy attachment, association); the agent add-on 1, or 1 import.

### IRSA

In place of Pod Identity. Same permissions policies. Trust policy: `sts:AssumeRoleWithWebIdentity` for the cluster OIDC provider, `sub` = `system:serviceaccount:ate-system:ate-api-server` and `system:serviceaccount:ate-system:atelet`. Chart values: `eks.amazonaws.com/role-arn: <role ARN>` in `apiServer.serviceAccount.annotations` and `atelet.serviceAccount.annotations`.

## Actor images

atelet pulls the image of each ActorTemplate container itself. The kubelet pulls only pod images: the Substrate components, the worker image (`ateworker-gvisor`) and PostgreSQL.

### Pull and cache (upstream `internal/imagecache`)

- Calls: `Run` (cold start, golden snapshot build) and `Restore` (every resume) resolve the image reference and ensure its layers.
- Tag reference: one manifest `HEAD` to the registry on every Run and Restore. Digest reference: no request when the node has the image. Use digest references in ActorTemplates.
- Cache: `/var/lib/ate/image-cache` on the node boot disk; unpacked layers, one copy per node, shared by all actors. A snapshot holds no image layers.
- A new node or a rebooted node starts with an empty cache (atelet empties it after a reboot): the first actor on it pulls the full image.
- Eviction, atelet defaults: a pass every 5m; from 85% boot disk usage down to 80%; least recently used first; images younger than 2m and images in use stay. The chart sets none of these flags.

### Registry credentials

- atelet takes registry credentials only from the kubelet credential provider plugin: chart values `atelet.imageCredentialProvider`. `enabled: false`: no plugin, every pull anonymous.
- atelet runs the plugin as a child process in the `atelet` container, with that container's environment. On EKS with Pod Identity, the plugin uses the role of `ate-system/atelet`.
- Node IAM role: not used. Pods do not reach IMDS on nodes with IMDSv2 and hop limit 1 (default of the `terraform-aws-modules/eks` node groups), and the AWS SDK takes the Pod Identity credentials first.
- The kubelet registry file `/var/lib/kubelet/config.json` (Docker Hub logins of the node) does not reach atelet.
- A failing plugin: atelet logs `Image credential provider failed; skipping it` and pulls anonymously.
- AL2023 EKS AMI plugin config `/etc/eks/image-credential-provider/config.json`: `ecr-credential-provider` for private ECR (`*.dkr.ecr.*.amazonaws.com` and the other partitions) and public ECR (`public.ecr.aws`). Docker Hub and `ghcr.io`: anonymous with or without the plugin.

| Actor images | Chart values | atelet role |
|---|---|---|
| Public registries only | `atelet.imageCredentialProvider.enabled: false` | S3 only |
| Private ECR, same account | `enabled: true`, `binDir: /etc/eks/image-credential-provider`, `config: /etc/eks/image-credential-provider/config.json` | plus `ecr:GetAuthorizationToken` on `*`; `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` on `arn:<partition>:ecr:<region>:<account>:repository/<images>/*` (Terraform variable `actor_images_prefix`) |
| Private ECR, other account | as above | as above, plus a repository policy that allows the atelet role |

Docker Hub limits anonymous pulls per source IP. Nodes behind one NAT share the limit. HTTP `429`: golden snapshot builds, and actor starts and resumes on nodes without the image fail; with tag references, every Run and Restore fails. Running actors stay. A copy of the image in `<images>` (`crane copy` or `skopeo copy`) and a digest reference to it avoid Docker Hub.

### ECR pull-through cache

- Rule: ECR repository prefix `<rule>` to an upstream registry, for example `registry-1.docker.io`. Account and Region scope.
- Upstream login: Secrets Manager secret named `ecr-pullthroughcache/<name>`, keys `username` and `accessToken`, in the account and Region of the rule. The ECR service reads it.
- Image reference: `<account>.dkr.ecr.<region>.amazonaws.com/<rule>/<repository>`. Docker Hub official images: `library/` in the path (`<rule>/library/nginx`).
- First pull: ECR creates the repository and imports the image. The caller needs `ecr:BatchImportUpstreamImage` and `ecr:CreateRepository` on `repository/<rule>/*`, plus the read actions above. Later pulls: from ECR; a tag is checked upstream at most once per 24 hours.
- A repository creation template for `<rule>` gives the cached repositories a lifecycle policy.

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
aws eks describe-addon --cluster-name <cluster> --addon-name eks-pod-identity-agent --query 'addon.[status,addonVersion]' --output text
kubectl -n kube-system rollout status daemonset/eks-pod-identity-agent --timeout=60s
```

Expected:

```text
ACTIVE  <agent version>
daemon set "eks-pod-identity-agent" successfully rolled out
```

`ResourceNotFoundException` or `daemonsets.apps "eks-pod-identity-agent" not found`: install the add-on `eks-pod-identity-agent`. `ACTIVE` but not in the Terraform state: import it (see [Terraform](#terraform)).

Version check:

```bash
aws eks describe-addon-versions --addon-name eks-pod-identity-agent --kubernetes-version <version> \
  --query "addons[0].addonVersions[?addonVersion=='<agent version>'].compatibilities[].clusterVersion" --output text
```

Expected: `<version>`. Empty: the version does not exist for that Kubernetes version.

### 3. VPC CNI network policy

```bash
kubectl -n kube-system get daemonset aws-node \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-eks-nodeagent")].args}{"\n"}'
```

`--enable-network-policy=true`: the `ate-system` NetworkPolicies apply.

`--enable-network-policy=false`: every NetworkPolicy object in the cluster has no effect.

- Actor egress: enforced by Substrate, with or without enforcement. atunnel sends all actor TCP to atenet-egress, which allows only the destinations of the actor's EgressPolicy; DNS answers only names of that policy; other protocols and link-local addresses (`169.254.0.0/16`, IMDS included) are blocked.
- `ate-system`: every pod in the cluster can connect to PostgreSQL, atelet and ate-api-server. Access still needs a client certificate (PostgreSQL, atelet) or a ServiceAccount token (ate-api-server).
- No NetworkPolicy boundary around WorkerPool namespaces or atenet-egress.

To turn it on: `enableNetworkPolicy: "true"` in the configuration values of the add-on `vpc-cni`. This starts enforcement of every NetworkPolicy in the cluster at once. First list them:

```bash
kubectl get networkpolicy -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)  types=\(.spec.policyTypes|tojson)  ingress=\(.spec.ingress|length? // 0)  egress=\(.spec.egress|length? // 0)"'
```

A listed type with 0 rules: deny all for that direction. `Egress` without a rule for port 53: no DNS.

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
kubectl get storageclass <default class> -o jsonpath='{.provisioner} {.volumeBindingMode} {.parameters}{"\n"}'
```

Expected: one StorageClass marked `(default)`, provisioner `ebs.csi.aws.com` or another `ReadWriteOnce` provisioner. None: set `postgres.storage.storageClassName`.

Size, chart value `postgres.storage.size`, default 500Gi:

- Content: control plane state only (actors, templates, workers, leases, tags). Snapshots are in S3. Kind test bed after many smoke runs: database 9 MB, data directory 64 MB.
- WAL: PostgreSQL defaults, `max_wal_size` 1GB, no archiving, no replication slots.
- 500Gi: upstream base, where disk IOPS grow with disk size. EBS gp3 (the EBS CSI driver default when the StorageClass sets no `type`): 3000 IOPS and 125 MiB/s at any size. gp2: 3 IOPS per GiB, minimum 100.
- Set once: the size is in the StatefulSet `volumeClaimTemplates`, which cannot change. A larger volume: resize PVC `data-postgres-0`, then delete the StatefulSet with `--cascade=orphan` and sync again.
- `volumeBindingMode: Immediate`: the volume is created in a zone before the pod schedules; `postgres-0` then runs only on nodes in that zone.

### 7. Egress

`<gvisor-url>`: an asset `url` of SandboxConfig `gvisor-default` (`deploy-templates/templates/sandboxconfig/gvisor.yaml`), `gs://` replaced by `https://storage.googleapis.com/`. One per node architecture and release.

Run in a pod, in a namespace whose Pod Security allows a plain pod:

```bash
for u in \
  gvisor=<gvisor-url> \
  issuer=https://oidc.eks.<region>.amazonaws.com/id/<ID>/.well-known/openid-configuration \
  s3=https://s3.<region>.amazonaws.com/ \
  eks-auth=https://eks-auth.<region>.api.aws/ \
  ghcr=https://ghcr.io/v2/
do
  n="${u%%=*}"
  printf '%s ' "$n"
  curl -sS -m 10 -o /dev/null -w '%{http_code}\n' "${u#*=}" 2>&1 | tail -1
done
```

Expected: `gvisor 200`, `issuer 200`; `s3`, `eks-auth`, `ghcr` with any HTTP status. `000`, a timeout or a resolve error: open the egress in [Egress](#egress).

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
| atelet | registries of the actor images | 443 | actor images; private ECR: `api.ecr.<region>.amazonaws.com`, `<account>.dkr.ecr.<region>.amazonaws.com`, S3 |

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
    enabled: true
    binDir: /etc/eks/image-credential-provider
    config: /etc/eks/image-credential-provider/config.json
postgres:
  storage:
    # Control plane state only; see Preflight, PostgreSQL volume.
    size: 5Gi
router:
  ingressAllowedSpiffeIds:
    - spiffe://cluster.local/ns/ate-system/sa/atenet-client
```

`router.ingressAllowedSpiffeIds`: client identities, `spiffe://cluster.local/ns/<namespace>/sa/<service-account>`, that may send traffic to actors through atenet-router. Each listed ID reaches every actor. Empty: no client reaches an actor. Not affected: the Substrate API (ate-api-server) and actor egress. Add an ID only for a service that calls ports inside actors.

### Argo CD

- `CreateNamespace=false`: the chart creates `ate-system` and `podcertificate-controller-system`.
- Client-side apply is enough: the largest objects, ConfigMap `atenet-egress` (about 62 KB) and CRD `workerpools.ate.dev` (about 35 KB), are below the 256 KiB annotation limit of `kubectl.kubernetes.io/last-applied-configuration`.
- Sync waves (`argocd.argoproj.io/sync-wave`, `krci-substrate.syncWave` in `_helpers.tpl`): `0` namespaces, CRDs and cluster-wide config; `1` CA objects, podcertificate-controller, SandboxConfig; `2` PostgreSQL and atelet; `3` control plane and dataplane. A wave starts after the earlier waves are healthy.

## After the install

### Install checks

```bash
kubectl -n ate-system get pods
kubectl -n podcertificate-controller-system get pods
kubectl -n ate-system logs deployment/ate-api-server -c objectstore-plugin | grep -m1 'Using S3 storage backend'
kubectl -n ate-system logs daemonset/atelet -c objectstore-plugin | grep -m1 'Using S3 storage backend'
kubectl -n ate-system get configmap ate-api-server-envvars -o jsonpath='{.data.ATE_API_SNAPSHOT_LOCATION}{"\n"}'
kubectl -n ate-system get pod -l app=atelet \
  -o jsonpath='{.items[0].spec.containers[?(@.name=="atelet")].env[*].name}{"\n"}'
kubectl -n ate-system logs daemonset/atelet -c atelet | grep -m1 'image credential providers'
```

Expected:

- All pods ready. atelet: one pod per node where its DaemonSet schedules; WorkerPools place workers only on those nodes.
- `Using S3 storage backend` twice; `s3://<bucket>/<prefix>/`.
- atelet environment: `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`.
- `imageCredentialProvider.enabled: true`: `Loaded image credential providers ... "providers":["ecr-credential-provider"]`. `No usable image credential providers`: wrong host paths.

`AccessDenied` in the `objectstore-plugin` logs of `deployment/ate-api-server` or `daemonset/atelet`: check the association, the trust policy conditions and `<keys>`.

### End-to-end check

The smoke tests run on the kind test bed only. The same steps by hand, with the objects of `e2e/chainsaw/02-actor/`. `kubectl ate` is a kubectl plugin (`kubectl-ate`, release of `KUBECTL_ATE_VERSION`, `make kubectl-ate` installs it into `.cache/bin/`): global flags go after `ate`, for example `kubectl ate --context <context> ...`. Without `--token-file`, `kubectl ate` acts as `ate-system/ate-client`, a bootstrap owner (`apiServer.bootstrapOwners`).

1. WorkerPool, one gVisor worker:

   ```bash
   kubectl create namespace krci-substrate-smoke
   kubectl -n krci-substrate-smoke apply -f e2e/chainsaw/02-actor/workerpool.yaml
   kubectl -n krci-substrate-smoke get workerpool smoke -o jsonpath='{.status.readyReplicas}{"\n"}'
   ```

   Expected: `1`.

2. Atespace and ActorTemplate; the golden snapshot (gVisor download, image pull, copy to S3):

   ```bash
   kubectl ate --context <context> create atespace krci-substrate-smoke
   kubectl ate --context <context> create actor-template -f e2e/chainsaw/02-actor/actor-template.yaml
   kubectl ate --context <context> get actor-template smoke -a krci-substrate-smoke -o json | jq '.status.goldenSnapshotStatus'
   ```

   Expected, after up to some minutes: `goldenTag.name` set, no `errorMessage`.

3. Actor: create, resume, suspend to S3, resume:

   ```bash
   kubectl ate --context <context> create actor smoke-1 -a krci-substrate-smoke --template smoke
   kubectl ate --context <context> resume actor smoke-1 -a krci-substrate-smoke
   kubectl ate --context <context> suspend actor smoke-1 -a krci-substrate-smoke --mode=sync
   kubectl ate --context <context> resume actor smoke-1 -a krci-substrate-smoke
   kubectl ate --context <context> get actor smoke-1 -a krci-substrate-smoke -o json \
     | jq '{state: .status.state, snapshots: [.status.snapshots[] | {owner, state: .durableSnapshot.state, uri: .durableSnapshot.object.snapshotUri}]}'
   ```

   Expected: `ACTOR_STATE_RUNNING`; a snapshot `SNAPSHOT_STORAGE_STATE_COMPLETED` under `s3://<bucket>/<prefix>/atespaces/krci-substrate-smoke/actors/`.

4. Objects in the bucket, with your own AWS credentials:

   ```bash
   aws s3 ls --recursive s3://<bucket>/<keys-of-the-atespace>
   ```

   `<keys-of-the-atespace>`: `<prefix>/atespaces/krci-substrate-smoke/`; empty prefix: `atespaces/krci-substrate-smoke/`. Expected: `tags/<uid>/` (golden snapshot) and `actors/<uid>/snapshots/<uid>/` (suspend), each with `manifest.json`, `checkpoint.img.zstd`, `pages.img.zstd`, `pages_meta.img.zstd` and `rootfs/`.

5. HTTP through atenet-router (`router.ingressAllowedSpiffeIds` with `atenet-client`):

   ```bash
   kubectl-ate --context <context> proxy actor smoke-1 18000:80 -a krci-substrate-smoke &
   curl -sS http://127.0.0.1:18000/ | head -1
   kill %1
   ```

   Expected: `Hostname: actor`.

6. Cleanup:

   ```bash
   kubectl ate --context <context> delete actor smoke-1 -a krci-substrate-smoke
   kubectl ate --context <context> delete actor-template smoke -a krci-substrate-smoke
   kubectl delete namespace krci-substrate-smoke
   ```

   ate-api-server then deletes the snapshots: the listing of step 4 becomes empty after some minutes.
