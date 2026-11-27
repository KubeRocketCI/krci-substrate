# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.5.x   | :white_check_mark: |

## Scope

- This repository: the Helm chart, its deviations from the upstream reference install, and the CI of the chart.
- Upstream Agent Substrate (images, binaries, upstream manifests): report to [upstream](https://github.com/agent-substrate/substrate). Report here as well when the chart ships the affected release.

## Reporting a Vulnerability

The KubeRocketCI team takes security vulnerabilities seriously. We appreciate your efforts to responsibly disclose your findings.

To report a security vulnerability, please follow these steps:

1. **DO NOT** disclose the vulnerability publicly on GitHub Issues or other public forums.
2. Email us at <SupportEPMD-EDP@epam.com> with a detailed description of the vulnerability.
3. Include the chart version, the upstream release, steps to reproduce, impact, and any potential mitigations if known.
4. Allow time for the team to investigate and address the vulnerability before any public disclosure.

## What to expect

- Acknowledgment of your report within 48 hours
- An initial assessment of the report within 7 days
- Regular updates about the progress of addressing the vulnerability
- Credit for discovering the vulnerability (unless you prefer to remain anonymous)

## Disclosure Policy

We follow a coordinated disclosure process:

1. Once a vulnerability is confirmed, we develop and test a fix
2. We prepare a security advisory to accompany the fix
3. We release the fix and publish the security advisory simultaneously
4. After the fix has been available for 10 days, details may be discussed publicly

## Security Model

| Surface | Protection |
|---|---|
| Network | NetworkPolicies of `ate-system` limit ingress only; they apply only when the CNI enforces NetworkPolicies. Actor egress: atenet-egress allows only the destinations of the actor's EgressPolicy ([docs/eks.md](docs/eks.md#3-vpc-cni-network-policy)) |
| Substrate API | ate-api-server verifies ServiceAccount tokens against `apiServer.serviceAccountIssuer`; `apiServer.bootstrapOwners` (default ServiceAccount `ate-system/ate-client`) has owner on `global:root` |
| PKI | CA pools and the JWT pool from cert-manager and External Secrets Operator ([ADR-0001](docs/adr/0001-pool-secrets-from-cert-manager-and-eso.md)); PostgreSQL and atelet accept client certificates only |
| Snapshots | S3 credentials from EKS Pod Identity or IRSA, scoped to the snapshot location ([docs/eks.md](docs/eks.md)); no AWS keys in the chart |
| Nodes | atelet runs as root on the `/var/lib/ate` hostPath, all capabilities dropped except the file capabilities in `deploy-templates/templates/atelet/daemonset.yaml`, no privilege escalation |

Thank you for helping us keep our project and our users secure!
