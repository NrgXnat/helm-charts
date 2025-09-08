{{/*
Create the name of the PostgreSQL service account to use
*/}}
{{- define "xnat.amq.fullname" -}}
{{- printf "%s-%s" .Release.Name "activemq-artemis" | trunc 63 | trimSuffix "-" -}}
{{- end -}}