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
make changelog      # CHANGELOG.md from commit titles (git-chglog); needs a v* tag or NEXT_RELEASE_TAG=X.Y.Z
```

Kind test bed (`hack/e2e-kind.sh`): `make e2e-kind-cluster-create` / `e2e-kind-cluster-delete` need Docker and Go, install kind into `bin/` (or use `KIND=<path>`); `make e2e-kind-install` needs kubectl, helm and jq; `make e2e-kind-smoke` needs kubectl, jq, curl and Go, installs chainsaw into `bin/` (or uses `CHAINSAW=<path>`) and kubectl-ate into `.cache/bin/`, and runs the Chainsaw tests of `e2e/chainsaw/`. Tools: versions pinned in `Makefile` (helm-docs, git-chglog, chainsaw, kind) and `hack/e2e-kind.sh` (kubectl-ate); installed as `<tool>-<version>`, so a version change installs the new one. CI cache key: `make tools-key TOOLS="<targets>"`, the tool versions only; a new tool gets a `TOOL_VERSION_<target>` in `Makefile`. Kubeconfig: `.cache/kind-krci-substrate.kubeconfig` only. `HELM_CA_FILE`: optional CA bundle for the chart registries.

## Layout

```
deploy-templates/            the chart; version = appVersion = chart release (X.Y.Z-SNAPSHOT on main)
deploy-templates/crds/       upstream manifests/ate-install/generated/ate.dev_*.yaml, byte for byte
deploy-templates/templates/  one directory per component, one file per kind group (serviceaccount, rbac, deployment);
                             objects of upstream manifests as the reference install has them
deploy-templates/templates/pki/  cert-manager and ESO objects of the pool Secrets (ADR-0001); pool list in _pools.tpl
deploy-templates/files/      upstream files the templates embed, byte for byte (postgres/setup.sql, atenet-egress/envoy.yaml)
deploy-templates/ci/         lint values: make helm-lint, ct lint
ct-configs/                  chart-testing and yamllint config
docs/eks.md                  EKS: S3 bucket, IAM roles, Pod Identity, Terraform, actor images (ECR), preflight, egress, install and end-to-end checks
e2e/kind/                    kind test bed: cluster config, dependency values, fixtures; not part of the chart
e2e/chainsaw/                smoke tests of an installed chart (Chainsaw), in directory order: 01-install, 02-actor
hack/e2e-kind.sh             kind test bed driver; versions of cert-manager and ESO at the top
.github/workflows/pr.yaml    commit title, helm-docs, chart-testing lint, kind test bed with Chainsaw tests
.github/workflows/release.yaml  GitHub release of a pushed tag v*, notes from .chglog/release.tpl.md
.github/workflows/tools-cache.yaml  tool caches of main (pull requests restore them); same tool sets as pr.yaml and release.yaml
.github/actions/tools/       restore, install and save Makefile tools; cache key from make tools-key
.github/ISSUE_TEMPLATE/, PULL_REQUEST_TEMPLATE.md, dependabot.yml  GitHub community files (dependabot: security updates of actions only)
.chglog/                     git-chglog config and templates (CHANGELOG.md, release notes)
CHANGELOG.md                 generated: make changelog; on main only [Unreleased] before the first tag
CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md, CODEOWNERS  community files, from the other KRCI repos
```

## Conventions

- Source of truth for every object: the reference install of the upstream release (`GLOSSARY.md`, Upstream). Copy objects from the upstream manifests of that tag; do not edit them by hand.
- Upstream release bump: the tag in `GLOSSARY.md` (Upstream), the image tags and digests in `deploy-templates/values.yaml`, the upstream links in `deploy-templates/README.md.gotmpl`, `KUBECTL_ATE_VERSION` in `hack/e2e-kind.sh`.
- Copy from a git checkout of the upstream tag, not from the Go module proxy: the proxy's `go.ate.dev/substrate@v1.0.1` is an earlier commit than the tag `v1.0.1` (`20778a6`).
- Namespaces are fixed in templates (`ate-system`, `podcertificate-controller-system`); never `{{ .Release.Namespace }}`.
- Every value has a `# --` helm-docs comment; run `make helm-docs` after a values change.
- Values: one top-level key per service. Shared keys only for settings of several services (`snapshots`, `pki`). Defaults equal the reference install.
- Add a value only for a setting that changes often (`image`, `replicas`) or that a known technical or business requirement needs. Keep probes, scheduling and other fields fixed in the templates, as the reference install has them.
- Chart deviations from the reference install: listed with a reason in `deploy-templates/README.md.gotmpl`, section Deviations.
- Chart versions: KRCI CI. `version` and `appVersion` in `deploy-templates/Chart.yaml` stay at the development version `X.Y.Z-SNAPSHOT` on `main`. A build of `main` publishes `X.Y.Z-SNAPSHOT.<build>` to `https://epam.github.io/edp-helm-charts/snapshot`; a release from `release/X.Y` publishes `X.Y.Z` to `.../stable`. Do not bump them in a PR, except the next development version on `main` after `release/X.Y` is cut.
- Release (`edp-delivery-custom-pipelines`, TriggerTemplate `github-krci-substrate-app-release-template`): on `release/X.Y`, sets `version` and `appVersion` to `X.Y.Z`, runs `make helm-docs` and `NEXT_RELEASE_TAG=X.Y.Z make changelog`, commits, tags `vX.Y.Z`, publishes the chart, pushes. The tag push runs `.github/workflows/release.yaml`. `CHANGELOG.md` and `make changelog` must be on the release branch.
- Commit messages: generate with `/krci-general:commit`. Title `EPMDEDP-<id>: <type>: <description>`, 10–85 characters, type one of `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore` (`.github/workflows/pr.yaml`). Sign off (`git commit -s`).
- Branch names start with the ticket key (`EPMDEDP-<id>-<slug>`).
- Jira keys appear only in commit titles, branch names, PR bodies, this file and `docs/agents/issue-tracker.md`.

## Agent skills

- Issue tracker: Jira project EPMDEDP through the mcp-atlassian tools, labels `krci-substrate` and `AI-generated`; pull requests on GitHub. `docs/agents/issue-tracker.md`.
- Triage labels: default five roles as Jira labels. `docs/agents/triage-labels.md`.
- Domain docs: single-context, the files named at the top. `docs/agents/domain.md`.
