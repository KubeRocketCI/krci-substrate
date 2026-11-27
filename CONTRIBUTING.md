# Contributing

Thanks for helping with krci-substrate, the Helm chart of upstream [Agent Substrate](https://github.com/agent-substrate/substrate) for KubeRocketCI. This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Issues

Search the [issues](https://github.com/KubeRocketCI/krci-substrate/issues) first, then use a template. A bug report names the chart version, the upstream release, the Kubernetes distribution and version, the values that differ from the defaults, the steps, and the expected and actual result.

Report a defect of Substrate itself, not of the chart, to [upstream](https://github.com/agent-substrate/substrate).

Never report a vulnerability in an issue: see [SECURITY.md](SECURITY.md).

## Pull requests

1. One pull request, one commit, branched from `main`.
2. Run the checks of CI: `make validate-docs helm-lint ct-lint`, then `make e2e-kind` on the kind test bed ([README.md](README.md#kind-test-bed)). After a change of `deploy-templates/values.yaml` or `README.md.gotmpl`, run `make helm-docs` first.
3. Copy chart objects from the upstream manifests of the release tag; do not edit them by hand. List a deviation from the reference install with its reason in `deploy-templates/README.md.gotmpl`, section Deviations. Terms: [GLOSSARY.md](GLOSSARY.md); decisions: [docs/adr/](docs/adr/).
4. Do not change `version` or `appVersion` in `deploy-templates/Chart.yaml`: the release pipeline sets them.
5. Write the commit title as `EPMDEDP-<ID>: <type>: <Subject>`, 10 to 85 characters, with the type `feat`, `fix`, `docs`, `style`, `refactor`, `test` or `chore`, and `!` after it for a breaking change. The title goes into [CHANGELOG.md](CHANGELOG.md).
6. Fill in the pull request template.
