# krci-substrate

Helm chart for [Agent Substrate](https://github.com/agent-substrate/substrate), for GitOps-managed KubeRocketCI clusters. Clusters consume it through [edp-cluster-add-ons](https://github.com/epam/edp-cluster-add-ons), the KubeRocketCI Argo CD add-ons catalog.

Each chart object copied from upstream equals its reference install object: what upstream `ate-setup deploy ate-system` applies for upstream release `v1.0.1` (envoy dataplane, non-kind cluster), apart from the deviations listed in the chart documentation. Objects are copied from the upstream manifests of that release tag.

The chart is in [`deploy-templates/`](deploy-templates/); its documentation is [`deploy-templates/README.md`](deploy-templates/README.md).

## Status

| Upstream objects | In the chart |
|---|---|
| Namespaces `ate-system`, `podcertificate-controller-system` | yes |
| CRDs `workerpools`, `sandboxconfigs`, `csidriverconfigs` (`ate.dev`) | yes |
| podcertificate-controller, its RBAC and ServiceAccount | yes |
| Pool Secrets (CA pools, JWT pool), from cert-manager and ESO | yes |
| Bundled PostgreSQL, ate-api-server, ate-idp-server, ate-controller, their config, Services, RBAC, PDBs | yes |
| NetworkPolicies of `ate-system`, ConfigMap `ate-otel-config` | yes |
| Dataplane: atelet, atenet-router, atenet-egress, k8s-credential-provider, SandboxConfig `gvisor-default` | yes |

## EKS

AWS resources (S3 bucket, IAM roles, Pod Identity associations), cluster preflight and egress: [`docs/eks.md`](docs/eks.md).

## Development

```bash
make helm-docs   # regenerate deploy-templates/README.md
make helm-lint   # lint and render the chart
```

### Kind test bed

Cluster `krci-substrate`, Kubernetes 1.37, context `kind-krci-substrate`. Its kubeconfig is `.cache/kind-krci-substrate.kubeconfig`; no other kubeconfig or cluster is touched. Manual access: `kubectl --kubeconfig .cache/kind-krci-substrate.kubeconfig …`.

```bash
make e2e-kind-cluster-create   # create the cluster, set proxy ARP on the nodes (Docker)
make e2e-kind                  # install dependencies and the chart, then smoke
make e2e-kind-install          # cert-manager, ESO, the chart, RustFS
make e2e-kind-smoke            # Chainsaw tests of e2e/chainsaw; stops at the first failure
make e2e-kind-cluster-delete   # delete the cluster (Docker)
```

Smoke tests (Chainsaw, `e2e/chainsaw/`), run in this order:

| Test | Asserts |
|---|---|
| `install` | namespaces `Active`; CRDs `Established`; the seven pool Secrets; podcertificate-controller `Available` and its three ClusterTrustBundles with a certificate; PostgreSQL, atelet and the six chart Deployments in `ate-system` ready; SandboxConfig `gvisor-default` class default; no PostgreSQL role has a password; both ate-api-server logins use client certificates |
| `actor` | atespace; WorkerPool `smoke` (`ateworker-gvisor` v1.0.1) with one ready worker on `gvisor-default`; golden snapshot of ActorTemplate `smoke`; actor `smoke-1` created suspended from the golden snapshot in S3; resumed; suspended with its snapshot in the RustFS fixture (a Job lists the objects); resumed; HTTP 200 through atenet-router with `kubectl ate proxy actor` |

At the end of the `actor` test, also after a failure, Chainsaw deletes the actor, the template and the listing Job, and the WorkerPool and its namespace when the test created them. A namespace `krci-substrate-smoke` that existed before the test stays with its objects. The atespace stays. JUnit report: `.cache/chainsaw-smoke.xml`.

| Object | Source |
|---|---|
| Kind config | `e2e/kind/cluster.yaml`: feature gates and kubelet settings of upstream `hack/create-kind-cluster.sh` |
| Proxy ARP | `make e2e-kind-cluster-create`: `docker exec` of `sysctl -w net.ipv4.conf.all.proxy_arp=1` on every node, as upstream `hack/create-kind-cluster.sh`; re-run it after a Docker restart |
| cert-manager, ESO | versions: constants at the top of `hack/e2e-kind.sh`; values: `e2e/kind/<release>-values.yaml` |
| RustFS S3 fixture | `e2e/kind/rustfs.yaml`, test only; credentials in Secret `ate-system/rustfs-credentials` |
| Chart | `deploy-templates/` with `e2e/kind/values.yaml`, release `default/krci-substrate`; installed without `helm --wait`, then waited for after RustFS |
| kubectl-ate | release binary of `KUBECTL_ATE_VERSION` (top of `hack/e2e-kind.sh`), sha256-checked, in `.cache/bin/` |
| chainsaw | `CHAINSAW_VERSION` in `Makefile`, the version of the operator repos; `go install` into `bin/` (needs Go); `CHAINSAW=<path>` uses an existing binary |
| kind | `KIND_VERSION` in `Makefile`; `go install` into `bin/` (needs Go); `KIND=<path>` uses an existing binary |
| Smoke WorkerPool and ActorTemplate | `e2e/chainsaw/02-actor/`, test only |

Every step is idempotent: a second run reports each release unchanged and each object unchanged. A dependency is skipped when deployed at its version, and helm installs the chart CRDs on first install only: after a dependency values change or a CRD change, recreate the cluster.

## License

[Apache License 2.0](LICENSE).
