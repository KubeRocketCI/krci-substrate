# krci-substrate

A Helm chart that installs upstream Agent Substrate as upstream `ate-setup` installs it, for GitOps-managed KubeRocketCI clusters.

Substrate terms (actor, worker, worker pool, snapshot, egress gateway): the `krci-agent-dispatcher` glossary, `github.com/KubeRocketCI/krci-agent-dispatcher/blob/main/GLOSSARY.md`, section Substrate.

## Chart

**Upstream**:
The Agent Substrate repository, `github.com/agent-substrate/substrate`, at the release tag the chart `appVersion` names.
_Avoid_: kagent, fork, source (alone)

**Reference install**:
The objects `ate-setup deploy ate-system` applies for the chart `appVersion` with the envoy dataplane on a non-kind cluster. Every chart object equals its reference install object.
_Avoid_: golden, baseline, expected manifest

**Upstream manifest**:
A file under `manifests/` of upstream; the chart copies its objects unchanged.
_Avoid_: template (for this), raw YAML
