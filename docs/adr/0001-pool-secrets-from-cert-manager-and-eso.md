# ADR-0001: Pool Secrets from cert-manager and ESO

Status: accepted

## Context

Upstream workloads mount seven Secrets by fixed name. Upstream `ate-setup` generates them once, in Go, and keeps an existing Secret:

| Secret | Namespace | Type | Keys | Key |
|---|---|---|---|---|
| `service-dns-ca-pool`, `pod-identity-ca-pool`, `postgres-ca-pool` | `podcertificate-controller-system` | `kubernetes.io/tls` | `pool`, `tls.crt`, `tls.key` | Ed25519 |
| `actor-id-ca-pool`, `egress-mitm-ca-pool` | `ate-system` | `kubernetes.io/tls` | `pool`, `tls.crt`, `tls.key` | ECDSA P-256 |
| `actor-id-ca-certs` | `ate-system` | `Opaque` | `ca.crt` | root of `actor-id-ca-pool` |
| `actor-id-jwt-pool` | `ate-system` | `Opaque` | `pool` | ECDSA P-256, ES256 |

A Helm chart under GitOps cannot run `ate-setup`, and must not render private keys from values.

## Decision

The chart always renders, per pool Secret, a cert-manager self-signed CA Certificate (PKCS8, 365 days, renewal 30 days before expiry, `rotationPolicy: Never`) and an ESO ExternalSecret. The ExternalSecret reads the Certificate Secret through a Kubernetes-provider SecretStore in the same namespace and templates the upstream Secret, `pool` JSON included.

cert-manager and ESO, with their CRDs, are cluster prerequisites. The chart does not check for them.

Pool contents:

- One entry with ID `"1"`, active for signing; `ate-setup` uses the same CA ID.
- `actor-id-jwt-pool` key ID: `"1"`. Upstream accepts any ID; its default, the public-key thumbprint, cannot be computed in an ESO template.

## Rejected

- Helm `genCA` or `genSignedCert` in templates: a new key at every render; under Argo CD every sync rotates the CAs.
- Helm hook Job that runs `ate-setup create`: an extra image and Secret-write RBAC; the Secrets are invisible to GitOps diff and are not renewed.
- Operator-supplied pool Secrets behind a values toggle: a second install path to test and document; cert-manager and ESO are prerequisites of every target cluster.

## Consequences

- Renewal keeps the private key and the subject. Leaf certificates issued before a renewal verify against the renewed root.
- ESO owns the pool Secrets. Pool edits with `kubectl ate admin` (add, activate, remove a CA or JWT key) are overwritten at the next refresh.
- With the cert-manager default `enableCertificateOwnerRef: false`, the Certificate Secrets stay after uninstall; a reinstall reuses their keys.
