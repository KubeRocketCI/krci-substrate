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
