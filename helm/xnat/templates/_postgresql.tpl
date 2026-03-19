{{/*
Create the name of the PostgreSQL service account to use
*/}}
{{- define "xnat.postgresql.fullname" -}}
{{- printf "%s-%s" .Release.Name "postgres-rw" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "xnat.postgresql.postgresqlUri" -}}
{{- if .Values.cnpg.cluster.external.postgresqlUri }}
{{- .Values.cnpg.cluster.postgresql.external.postgresqlUri }}
{{- else }}
{{- printf "%s-%s" .Release.Name "postgres-rw" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end -}}

{{- define "xnat.postgresql.postgresqlDatabase" -}}
{{- .Values.cnpg.cluster.database }}
{{- end -}}

{{- define "xnat.postgresql.postgresqlUsername" -}}
{{- .Values.cnpg.cluster.postgresqlUsername }}
{{- end -}}

{{- define "xnat.postgresql.postgresqlPassword" -}}
{{- .Values.cnpg.cluster.postgresqlPassword }}
{{- end -}}

{{- define "xnat.postgresql.clusterName" -}}
{{- if .Values.cnpg.cluster.name }}
{{- .Values.cnpg.cluster.name }}
{{- else }}
{{- printf "%s-%s" .Release.Name "postgres" }}
{{- end }}
{{- end -}}
