{{/*
Pool Secrets: name, type and keys as in upstream ate-setup (cmd/ate-setup/internal/steps/create.go).
Fields: namespace, secret (pool Secret), source (Certificate and its Secret; shared by pools of one CA),
format (caPool, caCerts, jwtPool), algorithm (cert-manager privateKey.algorithm; unset for caCerts).
Usage: include "krci-substrate.pools" . | fromYaml
*/}}
{{- define "krci-substrate.pools" -}}
namespaces:
  - podcertificate-controller-system
  - ate-system
pools:
  - {namespace: podcertificate-controller-system, secret: service-dns-ca-pool, source: krci-substrate-service-dns-ca, format: caPool, algorithm: Ed25519}
  - {namespace: podcertificate-controller-system, secret: pod-identity-ca-pool, source: krci-substrate-pod-identity-ca, format: caPool, algorithm: Ed25519}
  - {namespace: podcertificate-controller-system, secret: postgres-ca-pool, source: krci-substrate-postgres-ca, format: caPool, algorithm: Ed25519}
  - {namespace: ate-system, secret: actor-id-ca-pool, source: krci-substrate-actor-id-ca, format: caPool, algorithm: ECDSA}
  - {namespace: ate-system, secret: actor-id-ca-certs, source: krci-substrate-actor-id-ca, format: caCerts}
  - {namespace: ate-system, secret: egress-mitm-ca-pool, source: krci-substrate-egress-mitm-ca, format: caPool, algorithm: ECDSA}
  - {namespace: ate-system, secret: actor-id-jwt-pool, source: krci-substrate-actor-id-jwt, format: jwtPool, algorithm: ECDSA}
{{- end -}}

{{/*
ESO template expression: base64 DER body of the first <type> PEM block in ESO template variable <var>.
Input: dict "var" <ESO variable, e.g. .tlsKey> "type" <PEM type>.
*/}}
{{- define "krci-substrate.esoPEMBody" -}}
{{ printf `{{ %s | filterPEM "%s" | replace "-----BEGIN %s-----" "" | replace "-----END %s-----" "" | nospace }}` .var .type .type .type }}
{{- end -}}

{{/*
ESO template of a CA pool: upstream internal/localca Marshal of one CA, ID "1", active for signing.
*/}}
{{- define "krci-substrate.caPoolJSON" -}}
{"CAs":[{"ID":"1","SigningKeyPKCS8":"{{ include "krci-substrate.esoPEMBody" (dict "var" ".tlsKey" "type" "PRIVATE KEY") }}","RootCertificateDER":"{{ include "krci-substrate.esoPEMBody" (dict "var" ".tlsCrt" "type" "CERTIFICATE") }}"}],"ActiveForSigning":"1"}
{{- end -}}

{{/*
ESO template of a JWT pool: upstream internal/localjwtauthority Marshal of one ES256 authority, ID "1", active for signing.
*/}}
{{- define "krci-substrate.jwtPoolJSON" -}}
{"Authorities":[{"ID":"1","Algorithm":"ES256","SigningKeyPKCS8":"{{ include "krci-substrate.esoPEMBody" (dict "var" ".tlsKey" "type" "PRIVATE KEY") }}"}],"ActiveForSigning":"1"}
{{- end -}}
