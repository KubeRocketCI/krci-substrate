# krci-substrate

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v1.0.1](https://img.shields.io/badge/AppVersion-v1.0.1-informational?style=flat-square)

A Helm chart for upstream Agent Substrate, matching the upstream ate-setup install

**Homepage:** <https://docs.kuberocketci.io/>

## Introduction

The chart installs objects of [Agent Substrate](https://github.com/agent-substrate/substrate) `v1.0.1`, the release named by `appVersion`.
Each chart object equals its reference install object: what upstream `ate-setup deploy ate-system` applies for that release, with the envoy dataplane on a non-kind cluster.

The chart renders the namespaces and CRDs only, copied from the upstream manifests of the release tag:

| Chart path | Upstream path |
|---|---|
| `crds/ate.dev_*.yaml` | `manifests/ate-install/generated/ate.dev_*.yaml`, byte for byte |
| `templates/namespaces.yaml` | `manifests/ate-install/ate-system-namespace.yaml`, the Namespace of `manifests/ate-install/pod-certificate-controller.yaml` |

Namespaces are fixed: `ate-system` and `podcertificate-controller-system`. The release namespace is not used.

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

