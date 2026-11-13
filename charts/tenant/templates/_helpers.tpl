{{- define "tenant.dbCluster" -}}
{{- if eq .Values.db.cluster "restore" -}}
{{ .Release.Namespace }}-db-restore
{{- else -}}
{{ .Release.Namespace }}-db
{{- end -}}
{{- end -}}

{{/* Backups live under <tenant>/<namespace uid>: a re-created tenant never collides with an old archive. */}}
{{- define "tenant.backupPrefix" -}}
{{- if .Values.backup.namespaceUID -}}
{{ .Release.Namespace }}/{{ .Values.backup.namespaceUID }}
{{- else -}}
{{ .Release.Namespace }}
{{- end -}}
{{- end -}}
