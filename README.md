# krci-substrate

Helm chart for [Agent Substrate](https://github.com/agent-substrate/substrate), for GitOps-managed KubeRocketCI clusters. Clusters consume it through [edp-cluster-add-ons](https://github.com/epam/edp-cluster-add-ons), the KubeRocketCI Argo CD add-ons catalog.

Each chart object copied from upstream equals its reference install object: what upstream `ate-setup deploy ate-system` applies for the release in the chart `appVersion` (envoy dataplane, non-kind cluster). Objects are copied from the upstream manifests of that release tag.

The chart is in [`deploy-templates/`](deploy-templates/); its documentation is [`deploy-templates/README.md`](deploy-templates/README.md).

## Status

| Upstream objects | In the chart |
|---|---|
| Namespaces `ate-system`, `podcertificate-controller-system` | yes |
| CRDs `workerpools`, `sandboxconfigs`, `csidriverconfigs` (`ate.dev`) | yes |
| podcertificate-controller, its RBAC and ServiceAccount | yes |
| Pool Secrets (CA pools, JWT pool), from cert-manager and ESO | yes |
| PostgreSQL, control plane, dataplane | no |

## Development

```bash
make helm-docs   # regenerate deploy-templates/README.md
make helm-lint   # lint and render the chart
```

### Kind test bed

Cluster `krci-substrate`, Kubernetes 1.37, context `kind-krci-substrate`. Its kubeconfig is `.cache/kind-krci-substrate.kubeconfig`; no other kubeconfig or cluster is touched. Manual access: `kubectl --kubeconfig .cache/kind-krci-substrate.kubeconfig …`.

```bash
make e2e-kind-cluster-create   # create the cluster, set proxy ARP on the nodes (kind, Docker)
make e2e-kind                  # install dependencies and the chart, then smoke
make e2e-kind-install          # cert-manager, ESO, the chart, RustFS
make e2e-kind-smoke            # namespaces, CRDs, pool Secrets, podcertificate-controller, ClusterTrustBundles; stops at the first failed check
make e2e-kind-cluster-delete   # delete the cluster (kind, Docker)
```

| Object | Source |
|---|---|
| Kind config | `e2e/kind/cluster.yaml`: feature gates and kubelet settings of upstream `hack/create-kind-cluster.sh` |
| Proxy ARP | `make e2e-kind-cluster-create`: `docker exec` of `sysctl -w net.ipv4.conf.all.proxy_arp=1` on every node, as upstream `hack/create-kind-cluster.sh`; re-run it after a Docker restart |
| cert-manager, ESO | versions: constants at the top of `hack/e2e-kind.sh`; values: `e2e/kind/<release>-values.yaml` |
| RustFS S3 fixture | `e2e/kind/rustfs.yaml`, test only; credentials in Secret `ate-system/rustfs-credentials` |
| Chart | `deploy-templates/` with `e2e/kind/values.yaml`, release `default/krci-substrate` |

Every step is idempotent: a second run reports each release unchanged and each object unchanged. A dependency is skipped when deployed at its version, and helm installs the chart CRDs on first install only: after a dependency values change or a CRD change, recreate the cluster.

## License

[Apache License 2.0](LICENSE).
