# krci-substrate

A Helm chart that installs upstream Agent Substrate as upstream `ate-setup` installs it, for GitOps-managed KubeRocketCI clusters.

Substrate terms (actor, worker, worker pool, snapshot, egress gateway): the `krci-agent-dispatcher` glossary, `github.com/KubeRocketCI/krci-agent-dispatcher/blob/main/GLOSSARY.md`, section Substrate.

## Chart

**Upstream**:
The Agent Substrate repository, `github.com/agent-substrate/substrate`, at the release tag the chart `appVersion` names.
_Avoid_: kagent, fork, source (alone)

**Reference install**:
The objects `ate-setup deploy ate-system` applies for the chart `appVersion` with the envoy dataplane on a non-kind cluster. Every chart object copied from an upstream manifest equals its reference install object.
_Avoid_: golden, baseline, expected manifest

**Upstream manifest**:
A file under `manifests/` of upstream; the chart copies its objects unchanged, except where `ate-setup` changes them in the reference install (image references, `--preview=`).
_Avoid_: template (for this), raw YAML

## PKI

**Pool Secret**:
One of the seven upstream Secrets that hold a CA pool, a JWT pool or a CA root: `service-dns-ca-pool`, `pod-identity-ca-pool`, `postgres-ca-pool`, `actor-id-ca-pool`, `egress-mitm-ca-pool`, `actor-id-ca-certs`, `actor-id-jwt-pool`. The chart templates each one from a cert-manager Certificate with an ESO ExternalSecret (ADR-0001).
_Avoid_: CA secret, cert secret

**CA pool**:
The upstream `localca` JSON in key `pool`: CAs with signing key and root, one active for signing.
_Avoid_: CA bundle, keystore

**JWT pool**:
The upstream `localjwtauthority` JSON in key `pool` of `actor-id-jwt-pool`: signing keys, one active for signing.
_Avoid_: JWKS, key set
## Testing

**Kind test bed**:
The kind cluster `krci-substrate` (context `kind-krci-substrate`) with the chart, its dependencies and the fixtures installed by `make e2e-kind`.
_Avoid_: testbed, sandbox

**Fixture**:
An object the kind test bed installs that is neither the chart nor a dependency (cert-manager, ESO): the RustFS S3 fixture.
_Avoid_: mock, stub
