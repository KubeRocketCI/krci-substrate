<a name="unreleased"></a>
## [Unreleased]


<a name="v0.5.0"></a>
## v0.5.0 - 2026-11-27
### Features

- Add Substrate data plane and full kind smoke test
- Add bundled PostgreSQL and Substrate control plane
- Add pod-certificate controller and CA pool Secrets
- Add krci-substrate chart scaffold

### Testing

- Read the smoke test snapshot location from the installed chart
- Move kind smoke checks to Chainsaw
- Add kind test bed for the chart

### Routine

- Add changelog, GitHub release and community files
- Cache CI tools by version and seed the caches from main
- Version the chart with KRCI CI, pin upstream v1.0.1 in files
- Initialize repository

### Documentation

- Backport the EKS install findings to the EKS guide
- Add EKS install guide and snapshot key prefix


[Unreleased]: https://github.com/KubeRocketCI/krci-substrate/compare/v0.5.0...HEAD
