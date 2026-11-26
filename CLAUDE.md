# krci-substrate

`github.com/KubeRocketCI/krci-substrate`: a Helm chart for upstream Agent Substrate (`github.com/agent-substrate/substrate`). Chart only, no code.

Terms: `GLOSSARY.md`. Decisions: `docs/adr/`. Use the glossary terms in value names, comments and notes.

## Build & Check

```
make helm-docs      # deploy-templates/README.md from README.md.gotmpl
make validate-docs  # fail when README.md is stale
make helm-lint      # helm lint + helm template --include-crds
make ct-lint        # chart-testing lint against main (ct, yamllint, yamale on PATH)
make e2e-kind       # kind test bed: install on kind-krci-substrate, then smoke
```

Kind test bed (`hack/e2e-kind.sh`): `make e2e-kind-cluster-create` / `e2e-kind-cluster-delete` need kind and Docker; `make e2e-kind-install` needs kubectl, helm and jq; `make e2e-kind-smoke` needs kubectl, jq and curl (downloads kubectl-ate into `.cache/bin/`). Kubeconfig: `.cache/kind-krci-substrate.kubeconfig` only. `HELM_CA_FILE`: optional CA bundle for the chart registries.

## Layout

```
deploy-templates/            the chart; appVersion = upstream release tag
deploy-templates/crds/       upstream manifests/ate-install/generated/ate.dev_*.yaml, byte for byte
deploy-templates/templates/  one directory per component, one file per kind group (serviceaccount, rbac, deployment);
                             objects of upstream manifests as the reference install has them
deploy-templates/templates/pki/  cert-manager and ESO objects of the pool Secrets (ADR-0001); pool list in _pools.tpl
deploy-templates/files/      upstream files the templates embed, byte for byte (postgres/setup.sql)
deploy-templates/ci/         lint values: make helm-lint, ct lint
ct-configs/                  chart-testing and yamllint config
e2e/kind/                    kind test bed: cluster config, dependency values, fixtures; not part of the chart
hack/e2e-kind.sh             kind test bed driver; versions of cert-manager and ESO at the top
.github/workflows/pr.yaml    commit title, helm-docs, chart-testing lint
```

## Conventions

- Source of truth for every object: the reference install of the chart `appVersion`. Copy objects from the upstream manifests of that tag; do not edit them by hand.
- Copy from a git checkout of the upstream tag, not from the Go module proxy: the proxy's `go.ate.dev/substrate@v1.0.1` is an earlier commit than the tag `v1.0.1` (`20778a6`).
- Namespaces are fixed in templates (`ate-system`, `podcertificate-controller-system`); never `{{ .Release.Namespace }}`.
- Every value has a `# --` helm-docs comment; run `make helm-docs` after a values change.
- Values: one top-level key per service. Shared keys only for settings of several services (`snapshots`, `pki`). Defaults equal the reference install.
- Add a value only for a setting that changes often (`image`, `replicas`) or that a known technical or business requirement needs. Keep probes, scheduling and other fields fixed in the templates, as the reference install has them.
- Chart deviations from the reference install: listed with a reason in `deploy-templates/README.md.gotmpl`, section Deviations.
- A chart change bumps `version` in `deploy-templates/Chart.yaml` (`ct lint` checks it).
- Commit messages: generate with `/krci-general:commit`. Title `EPMDEDP-<id>: <type>: <description>`, 10–85 characters, type one of `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore` (`.github/workflows/pr.yaml`). Sign off (`git commit -s`).
- Branch names start with the ticket key (`EPMDEDP-<id>-<slug>`).
- Jira keys appear only in commit titles, branch names, PR bodies, this file and `docs/agents/issue-tracker.md`.

## Agent skills

- Issue tracker: Jira project EPMDEDP through the mcp-atlassian tools, labels `krci-substrate` and `AI-generated`; pull requests on GitHub. `docs/agents/issue-tracker.md`.
- Triage labels: default five roles as Jira labels. `docs/agents/triage-labels.md`.
- Domain docs: single-context, the files named at the top. `docs/agents/domain.md`.
