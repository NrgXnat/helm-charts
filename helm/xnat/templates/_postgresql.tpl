{{/*
Create the name of the PostgreSQL service account to use
*/}}
{{- define "xnat.postgresql.fullname" -}}
{{- printf "%s-%s" .Release.Name "postgres-rw" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "xnat.postgresql.postgresqlUri" -}}
{{- if .Values.cnpg.external.postgresqlUri }}
{{- .Values.cnpg.external.postgresqlUri }}
{{- else }}
{{- printf "%s-%s" .Release.Name "postgres-rw" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end -}}

{{- define "xnat.postgresql.postgresqlPort" -}}
{{- if .Values.cnpg.external.postgresqlPort }}
{{- .Values.cnpg.external.postgresqlPort }}
{{- else }}
{{- printf "5432"}}
{{- end }}
{{- end -}}

{{- define "xnat.postgresql.postgresqlDatabase" -}}
{{- .Values.cnpg.cluster.credentials.database }}
{{- end -}}

{{- define "xnat.postgresql.postgresqlUsername" -}}
{{- .Values.cnpg.cluster.credentials.username }}
{{- end -}}

{{- define "xnat.postgresql.postgresqlPassword" -}}
{{- .Values.cnpg.cluster.credentials.password }}
{{- end -}}

{{- define "xnat.postgresql.clusterName" -}}
{{- if .Values.cnpg.cluster.name }}
{{- .Values.cnpg.cluster.name }}
{{- else }}
{{- printf "%s-%s" .Release.Name "postgres" }}
{{- end }}
{{- end -}}
