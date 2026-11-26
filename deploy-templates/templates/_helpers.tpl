{{/*
Image reference <repository>:<tag>[@<digest>] of a service.
Input: dict "image" <values image map> "path" <values path of the map, for errors>.
*/}}
{{- define "krci-substrate.image" -}}
{{- $image := required (printf "%s is required" .path) .image -}}
{{- $repository := required (printf "%s.repository is required" .path) $image.repository -}}
{{- $tag := required (printf "%s.tag is required" .path) $image.tag -}}
{{- $ref := printf "%s:%s" $repository $tag -}}
{{- with $image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" .) -}}
{{- fail (printf "%s.digest must be sha256:<64 hex>" $.path) -}}
{{- end -}}
{{- $ref = printf "%s@%s" $ref . -}}
{{- end -}}
{{- $ref -}}
{{- end -}}

{{/*
Argo CD sync-wave annotation of an install phase. Argo CD applies a wave after the objects of earlier waves are healthy.
Phases: base (namespaces, CRDs, cluster-wide config), pki (CA objects, podcertificate-controller, SandboxConfig),
postgres-atelet (PostgreSQL, atelet), control-dataplane (control plane and dataplane). CRDs (crds/) carry no annotation: wave 0.
Input: phase name.
*/}}
{{- define "krci-substrate.syncWave" -}}
{{- $waves := dict "base" "0" "pki" "1" "postgres-atelet" "2" "control-dataplane" "3" -}}
argocd.argoproj.io/sync-wave: {{ required (printf "unknown sync phase %q" .) (get $waves .) | quote }}
{{- end -}}

{{/*
S3 environment of an objectstore-plugin sidecar, from snapshots.s3. Same for every sidecar.
Credentials only from snapshots.s3.credentialsSecret; empty: AWS SDK default chain.
Input: root context. Output: env list items, column 0.
*/}}
{{- define "krci-substrate.s3Env" -}}
- name: ATE_STORAGE_BACKEND
  value: "s3"
{{- with .Values.snapshots.s3 }}
- name: AWS_REGION
  value: {{ required "snapshots.s3.region is required" .region | quote }}
{{- with .endpoint }}
- name: AWS_ENDPOINT_URL
  value: {{ . | quote }}
{{- end }}
{{- if .usePathStyle }}
- name: AWS_S3_USE_PATH_STYLE
  value: "true"
{{- end }}
{{- with .credentialsSecret }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ . | quote }}
      key: AWS_ACCESS_KEY_ID
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ . | quote }}
      key: AWS_SECRET_ACCESS_KEY
{{- end }}
{{- end }}
{{- end -}}
