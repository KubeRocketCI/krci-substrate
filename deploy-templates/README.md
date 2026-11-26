# krci-substrate

![Version: 0.2.0](https://img.shields.io/badge/Version-0.2.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v1.0.1](https://img.shields.io/badge/AppVersion-v1.0.1-informational?style=flat-square)

A Helm chart for upstream Agent Substrate, matching the upstream ate-setup install

**Homepage:** <https://docs.kuberocketci.io/>

## Introduction

The chart installs objects of [Agent Substrate](https://github.com/agent-substrate/substrate) `v1.0.1`, the release named by `appVersion`.
Each chart object copied from upstream equals its reference install object: what upstream `ate-setup deploy ate-system` applies for that release, with the envoy dataplane on a non-kind cluster.

Objects copied from the upstream manifests of the release tag:

| Chart path | Upstream path |
|---|---|
| `crds/ate.dev_*.yaml` | `manifests/ate-install/generated/ate.dev_*.yaml`, byte for byte |
| `templates/namespaces.yaml` | `manifests/ate-install/ate-system-namespace.yaml`, the Namespace of `manifests/ate-install/pod-certificate-controller.yaml` |
| `templates/podcertificate-controller/serviceaccount.yaml` | the ServiceAccount of `manifests/ate-install/pod-certificate-controller.yaml` |
| `templates/podcertificate-controller/rbac.yaml` | the ClusterRole, ClusterRoleBinding, Role and RoleBinding of `manifests/ate-install/pod-certificate-controller.yaml` |
| `templates/podcertificate-controller/deployment.yaml` | the Deployment of `manifests/ate-install/pod-certificate-controller.yaml`; image `images.podcertcontroller` (`<repository>:<tag>@<digest>`) and `--preview=`, as the reference install has them |

Chart objects without an upstream manifest: `templates/pki/`, the cert-manager and ESO objects of the pool Secrets. The pool list: `templates/pki/_pools.tpl`.

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

```bash
helm install krci-substrate ./deploy-templates
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
| images.podcertcontroller.digest | string | `"sha256:46aa01a624053c23080da41ea37937afc5b544cecf77088ab2196b4ffb734b4f"` | Image digest (sha256:...) of the tag. Bump it with appVersion. Empty: tag only. |
| images.podcertcontroller.repository | string | `"ghcr.io/agent-substrate/substrate/podcertcontroller"` | Image repository of podcertificate-controller. |
| images.podcertcontroller.tag | string | `"v1.0.1"` | Image tag. Bump it with appVersion. |
| pki.certManager.duration | string | `"8760h"` | Lifetime of each CA certificate (upstream: 365 days). |
| pki.certManager.renewBefore | string | `"720h"` | Renewal lead time before CA certificate expiry. Renewal keeps the private key. |
| pki.externalSecrets.refreshInterval | string | `"1h"` | Interval at which ESO re-reads CA certificate Secrets into pool Secrets. |
