{{- define "tenant.dbCluster" -}}
{{- if eq .Values.db.cluster "restore" -}}
{{ .Release.Namespace }}-db-restore
{{- else -}}
{{ .Release.Namespace }}-db
{{- end -}}
{{- end -}}