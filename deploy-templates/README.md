# krci-substrate

![Version: 0.3.0](https://img.shields.io/badge/Version-0.3.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v1.0.1](https://img.shields.io/badge/AppVersion-v1.0.1-informational?style=flat-square)

A Helm chart for upstream Agent Substrate, matching the upstream ate-setup install

**Homepage:** <https://docs.kuberocketci.io/>

## Introduction

The chart installs objects of [Agent Substrate](https://github.com/agent-substrate/substrate) `v1.0.1`, the release named by `appVersion`.
Each chart object copied from upstream equals its reference install object: what upstream `ate-setup deploy ate-system` applies for that release, with the envoy dataplane on a non-kind cluster. Exceptions: [Deviations from the reference install](#deviations-from-the-reference-install).

Objects copied from the upstream manifests of the release tag:

| Chart path | Upstream path |
|---|---|
| `crds/ate.dev_*.yaml` | `manifests/ate-install/generated/ate.dev_*.yaml`, byte for byte |
| `templates/namespaces.yaml` | `manifests/ate-install/ate-system-namespace.yaml`, the Namespace of `manifests/ate-install/pod-certificate-controller.yaml` |
| `templates/podcertificate-controller/serviceaccount.yaml` | the ServiceAccount of `manifests/ate-install/pod-certificate-controller.yaml` |
| `templates/podcertificate-controller/rbac.yaml` | the ClusterRole, ClusterRoleBinding, Role and RoleBinding of `manifests/ate-install/pod-certificate-controller.yaml` |
| `templates/podcertificate-controller/deployment.yaml` | the Deployment of `manifests/ate-install/pod-certificate-controller.yaml`; image `podcertificateController.image` (`<repository>:<tag>@<digest>`) and `--preview=`, as the reference install has them |
| `templates/postgres/` | ConfigMap `postgres-config`, Service and StatefulSet of `manifests/ate-install/postgres/postgres.yaml` |
| `templates/ate-api-server/` | ClusterRole, ServiceAccount, ClusterRoleBinding, Deployment, PodDisruptionBudget and Service `api` of `manifests/ate-install/ate-api-server.yaml` |
| `templates/ate-idp-server/` | ServiceAccount, Deployment, PodDisruptionBudget and Service `idp` of `manifests/ate-install/ate-idp-server.yaml` |
| `templates/ate-controller/` | ServiceAccounts `ate-client`, `ate-controller`, the bindings, Service and Deployment of `manifests/ate-install/ate-controller.yaml`; ClusterRole and Role of `manifests/ate-install/generated/role.yaml` |
| `templates/networkpolicies.yaml` | `manifests/ate-install/ate-system-networkpolicies.yaml` |
| `templates/ate-otel-config.yaml` | `manifests/ate-install/ate-otel-config.yaml` |
| `files/postgres/setup.sql` | `pkg/postgressetup/setup.sql`, byte for byte |

Reference install changes in every substrate workload: image `<service>.image` (`<repository>:<tag>@<digest>`), `--preview=` appended. ate-api-server: `--authz-bootstrap-owners` appended, pod template annotation `ate.dev/env-hash`. ate-idp-server: `--issuer=https://idp.ate-system.svc` appended.

Chart objects without an upstream manifest:

- `templates/pki/`: the cert-manager and ESO objects of the pool Secrets. The pool list: `templates/pki/_pools.tpl`.
- `templates/ate-api-server/config.yaml`: the objects `ate-setup` writes for ate-api-server, bundled PostgreSQL: ConfigMaps `ate-api-server-envvars`, `ate-api-config`, `ate-api-authentication`, Secret `ate-api-server-secret-envvars`.
- `templates/postgres/configmap.yaml`, ConfigMap `postgres-setup`: the setup SQL run of `ate-setup`.

### Deviations from the reference install

| Object | Reference install | Chart | Reason |
|---|---|---|---|
| ate-api-server, sidecar `objectstore-plugin` | GCS (`ATE_STORAGE_BACKEND=gcs`, ambient Google credentials) | S3: `ATE_STORAGE_BACKEND=s3`, `AWS_REGION`, optional `AWS_ENDPOINT_URL`, `AWS_S3_USE_PATH_STYLE`; `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` only from `snapshots.s3.credentialsSecret` | Target clusters are EKS and kind. Production: no Secret; AWS SDK default chain with EKS Pod Identity or IRSA. The Secret is for the kind test bed or an S3-compatible store with no workload identity. |
| ServiceAccount `ate-api-server` | no annotations | `apiServer.serviceAccount.annotations` | IRSA needs `eks.amazonaws.com/role-arn` on the ServiceAccount. Default: no annotations. |
| ConfigMap `ate-api-server-envvars` | `ATE_API_SNAPSHOT_LOCATION` from `--snapshot-location` | `s3://<snapshots.s3.bucket>/` | S3 bucket. The S3 backend reads the bucket from the URI host. |
| ConfigMap `ate-api-authentication` | issuer from GKE coordinates or cluster OIDC discovery | `apiServer.serviceAccountIssuer` | A chart cannot query the cluster. EKS: the cluster OIDC issuer URL. |
| ConfigMap `ate-otel-config` | `OTEL_EXPORTER_OTLP_ENDPOINT` of the GKE managed collector | no endpoint; `OTEL_TRACES_EXPORTER`, `OTEL_METRICS_EXPORTER`, `ATE_WORKER_OTEL_TRACES_EXPORTER`, `ATE_WORKER_OTEL_METRICS_EXPORTER`: `none` | No collector on the target clusters yet. Logs stay on stdout. |
| StatefulSet `postgres` | `ate-setup` runs the setup SQL with `kubectl exec` after each rollout | the image entrypoint runs it from `/docker-entrypoint-initdb.d`, on an empty data directory only | No exec under GitOps. An existing volume keeps its roles and schema. |
| StatefulSet `postgres` | base size: resources and 500Gi claim; StorageClass from `--postgres-storage-class` | `postgres.resources`, `postgres.storage` | Default is the base size. Kind: the upstream kind overlay values. |

### S3 access

Every pod with an `objectstore-plugin` sidecar reads and writes the snapshot bucket with its own credentials. ate-api-server does not pass credentials to other pods.

| Pod | Sidecar mode | S3 use | ServiceAccount |
|---|---|---|---|
| ate-api-server | `control` | copies snapshots for tags; deletes snapshots nothing refers to | `ate-system/ate-api-server` |
| atelet (dataplane, not in the chart yet) | `node` | uploads and downloads snapshot files; reads sandbox assets | `ate-system/atelet` |

- Give S3 access to both ServiceAccounts: one EKS Pod Identity association each, or the IRSA annotation `eks.amazonaws.com/role-arn` in `<service>.serviceAccount.annotations`.
- `snapshots.s3` is the shared S3 environment of both sidecars, `snapshots.s3.credentialsSecret` included.
- No other pod uses object storage: ate-idp-server, ate-controller, atenet, worker pods.

## Values

One top-level key per service. A value exists only for a setting that changes often or that a known requirement needs. All other fields are fixed in the templates, as the reference install has them.

| Key | Service | Values |
|---|---|---|
| `podcertificateController` | podcertificate-controller | `image`, `replicas` |
| `postgres` | bundled PostgreSQL (one replica) | `image`, `resources`, `storage` |
| `apiServer` | ate-api-server, sidecar `objectstorePlugin` | `image`, `replicas`, `serviceAccountIssuer`, `bootstrapOwners`, `serviceAccount.annotations`, `objectstorePlugin.image` |
| `idpServer` | ate-idp-server | `image`, `replicas` |
| `controller` | ate-controller | `image`, `replicas` |

Shared keys: `snapshots.s3` (every objectstore-plugin sidecar), `pki` (pool Secrets).

Defaults are the reference install.

## Control plane

- PostgreSQL logins: `substrate_owner_user` and `substrate_readwrite_user`, client certificates from signer `postgres.podcert.ate.dev/identity` (pg_hba.conf `cert`). No role has a password.
- The setup SQL runs at database init only (ADR-0002). If the first init fails, the data directory stays without roles or schema, and ate-api-server cannot log in. Recovery: run the setup again; it is idempotent and keeps data:

  ```bash
  kubectl -n ate-system exec postgres-0 -c postgres -- sh /docker-entrypoint-initdb.d/substrate-setup.sh
  ```
- ate-api-server reaches the database at `postgres.ate-system.svc:5432`, `sslmode=verify-full`.
- `kubectl ate` port-forwards to Service `ate-system/api` and mints a token for ServiceAccount `ate-system/ate-client`, a bootstrap owner by default (`apiServer.bootstrapOwners`). For a shared install, set it to your operator principals.
- A change of `templates/ate-api-server/config.yaml` changes `ate.dev/env-hash` and rolls ate-api-server.

Namespaces are fixed: `ate-system` and `podcertificate-controller-system`. The release namespace is not used.

## Prerequisites

The chart does not check them.

- Kubernetes 1.37: `certificates.k8s.io/v1beta1` API (PodCertificateRequest) served; feature gates `ClusterTrustBundle`, `ClusterTrustBundleProjection`, `PodCertificateRequest` enabled. Kind: `e2e/kind/cluster.yaml`.
- cert-manager with CRDs (`cert-manager.io/v1`).
- External Secrets Operator with CRDs (`external-secrets.io/v1`).

## PKI

The pool Secrets are the seven Secrets the upstream workloads mount, with the upstream names, types and keys:

- cert-manager self-signed CA Certificates `krci-substrate-*` hold the keys.
- ESO ExternalSecrets template each pool Secret, `pool` JSON included.
- CA ID and JWT key ID: `"1"`.

podcertificate-controller starts when `service-dns-ca-pool`, `pod-identity-ca-pool` and `postgres-ca-pool` exist. It then publishes the ClusterTrustBundles `servicedns`, `podidentity` and `postgres` `.podcert.ate.dev:identity:primary-bundle`.

### CA expiry and renewal

- Each CA certificate is valid for `pki.certManager.duration`. cert-manager renews it `pki.certManager.renewBefore` before expiry. Defaults: [Values](#values).
- Renewal keeps the private key (`rotationPolicy: Never`) and the subject. Leaf certificates issued before a renewal verify against the renewed root.
- ESO copies the renewed certificate into the pool Secret within `pki.externalSecrets.refreshInterval`. The upstream workloads reload the pool within a minute after the kubelet updates the mounted Secret.
- Renew now: `cmctl renew --namespace <namespace> krci-substrate-<name>`, then annotate the ExternalSecret with `force-sync=<timestamp>`.
- ESO owns the pool Secrets: edits with `kubectl ate admin` are overwritten at the next refresh.

## Deploy with Helm

`snapshots.s3.bucket` and `snapshots.s3.region` are required.

```bash
helm install krci-substrate ./deploy-templates \
  --set snapshots.s3.bucket=<bucket> --set snapshots.s3.region=<region> \
  --set apiServer.serviceAccountIssuer=<issuer>
```

Helm installs `crds/` on first install only; it does not upgrade them.

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| epmd-edp | <SupportEPMD-EDP@epam.com> | <https://solutionshub.epam.com/solution/kuberocketci> |

## Source Code

* <https://github.com/KubeRocketCI/krci-substrate>
* <https://github.com/agent-substrate/substrate>

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| apiServer.bootstrapOwners | string | `"system:serviceaccount:ate-system:ate-client"` | Comma-separated principals granted owner on global:root. Default: ServiceAccount ate-system/ate-client, the token `kubectl ate` mints. Shared install: the operator principals. |
| apiServer.image.digest | string | `"sha256:5d9f6da2e1446766a48908764891cc3c66cc6ff657279415c0d3839d5e9476ee"` | Image digest `sha256:<64 hex>`. Empty: tag only. |
| apiServer.image.repository | string | `"ghcr.io/agent-substrate/substrate/ateapi"` | Image repository. |
| apiServer.image.tag | string | `"v1.0.1"` | Image tag. |
| apiServer.objectstorePlugin.image.digest | string | `"sha256:311cc9cfb9ee8c344f3ebc3e4d5cafb88468840023b62d1c47c6338ed32b0352"` | Image digest `sha256:<64 hex>`. Empty: tag only. |
| apiServer.objectstorePlugin.image.repository | string | `"ghcr.io/agent-substrate/substrate/objectstore-plugin"` | Image repository. |
| apiServer.objectstorePlugin.image.tag | string | `"v1.0.1"` | Image tag. |
| apiServer.replicas | int | `2` | Replica count. |
| apiServer.serviceAccount.annotations | object | `{}` | ServiceAccount annotations. IRSA: `eks.amazonaws.com/role-arn: arn:aws:iam::<account>:role/<role>`. |
| apiServer.serviceAccountIssuer | string | `""` |  |
| controller.image.digest | string | `"sha256:b63519a821f4c702a689caf5b1ff549a8d6134ac3da94def30c71f914a70d614"` | Image digest `sha256:<64 hex>`. Empty: tag only. |
| controller.image.repository | string | `"ghcr.io/agent-substrate/substrate/atecontroller"` | Image repository. |
| controller.image.tag | string | `"v1.0.1"` | Image tag. |
| controller.replicas | int | `1` | Replica count. |
| idpServer.image.digest | string | `"sha256:5d9302255998a3f376cbea8d8860488d20b6c030417c0c3ea7fba53a67f2c9f7"` | Image digest `sha256:<64 hex>`. Empty: tag only. |
| idpServer.image.repository | string | `"ghcr.io/agent-substrate/substrate/ate-idp-server"` | Image repository. |
| idpServer.image.tag | string | `"v1.0.1"` | Image tag. |
| idpServer.replicas | int | `2` | Replica count. |
| pki.certManager.duration | string | `"8760h"` | Lifetime of each CA certificate (upstream: 365 days). |
| pki.certManager.renewBefore | string | `"720h"` | Renewal lead time before CA certificate expiry. Renewal keeps the private key. |
| pki.externalSecrets.refreshInterval | string | `"1h"` | Interval at which ESO re-reads CA certificate Secrets into pool Secrets. |
| podcertificateController.image.digest | string | `"sha256:46aa01a624053c23080da41ea37937afc5b544cecf77088ab2196b4ffb734b4f"` | Image digest `sha256:<64 hex>`. Empty: tag only. |
| podcertificateController.image.repository | string | `"ghcr.io/agent-substrate/substrate/podcertcontroller"` | Image repository. |
| podcertificateController.image.tag | string | `"v1.0.1"` | Image tag. |
| podcertificateController.replicas | int | `1` | Replica count. |
| postgres.image.digest | string | `"sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15"` | Image digest `sha256:<64 hex>`. Empty: tag only. |
| postgres.image.repository | string | `"postgres"` | Image repository, shared by PostgreSQL and the tls-reloader sidecar. |
| postgres.image.tag | string | `"18-alpine"` | Image tag. |
| postgres.resources | object | `{"limits":{"cpu":"16","memory":"2Gi"},"requests":{"cpu":"2","memory":"1Gi"}}` | Upstream base. Sized for the activation load of the whole control plane. |
| postgres.storage.size | string | `"500Gi"` | Upstream base. Headroom for WAL churn; also scales provisioned IOPS on some storage classes. |
| postgres.storage.storageClassName | string | `""` | Empty: cluster default StorageClass. |
| snapshots.s3.bucket | string | `""` | Required. S3 bucket name rules. |
| snapshots.s3.credentialsSecret | string | `""` | Existing Secret in ate-system with keys AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY. Credentials come only from a Secret, never from values. Use only for the kind test bed or an S3-compatible store without workload identity. EKS: leave empty (AWS SDK default credential chain) and give S3 access to ate-system/ate-api-server, and with the dataplane ate-system/atelet, through EKS Pod Identity or IRSA (`<service>.serviceAccount.annotations`). |
| snapshots.s3.endpoint | string | `""` | AWS_ENDPOINT_URL. Empty: the AWS endpoint of the region. |
| snapshots.s3.region | string | `""` | Required. AWS_REGION. |
| snapshots.s3.usePathStyle | bool | `false` | AWS_S3_USE_PATH_STYLE. Set for MinIO, RustFS and other S3-compatible stores. |
