# krci-substrate

Helm chart for [Agent Substrate](https://github.com/agent-substrate/substrate), for GitOps-managed KubeRocketCI clusters. Clusters consume it through [edp-cluster-add-ons](https://github.com/epam/edp-cluster-add-ons), the KubeRocketCI Argo CD add-ons catalog.

Each chart object equals its reference install object: what upstream `ate-setup deploy ate-system` applies for the release in the chart `appVersion` (envoy dataplane, non-kind cluster). Objects are copied from the upstream manifests of that release tag.

The chart is in [`deploy-templates/`](deploy-templates/); its documentation is [`deploy-templates/README.md`](deploy-templates/README.md).

## Status

| Upstream objects | In the chart |
|---|---|
| Namespaces `ate-system`, `podcertificate-controller-system` | yes |
| CRDs `workerpools`, `sandboxconfigs`, `csidriverconfigs` (`ate.dev`) | yes |
| podcertificate-controller, CA pools, PostgreSQL, control plane, dataplane | no |

## Development

```bash
make helm-docs   # regenerate deploy-templates/README.md
make helm-lint   # lint and render the chart
```

## License

[Apache License 2.0](LICENSE).
