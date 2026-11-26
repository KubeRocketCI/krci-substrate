{{/*
Image of an upstream component: <repository>:<tag>[@<digest>] from images.<name>.
Input: dict "root" $ "name" <key under images>.
*/}}
{{- define "krci-substrate.image" -}}
{{- $image := required (printf "images.%s is required" .name) (get .root.Values.images .name) -}}
{{- $repository := required (printf "images.%s.repository is required" .name) $image.repository -}}
{{- $tag := required (printf "images.%s.tag is required" .name) $image.tag -}}
{{- $ref := printf "%s:%s" $repository $tag -}}
{{- with $image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" .) -}}
{{- fail (printf "images.%s.digest must be sha256:<64 hex>" $.name) -}}
{{- end -}}
{{- $ref = printf "%s@%s" $ref . -}}
{{- end -}}
{{- $ref -}}
{{- end -}}
