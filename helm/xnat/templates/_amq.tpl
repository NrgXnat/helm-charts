{{- define "xnat.activemq.username" -}}
{{- .Values.activemq.broker.user }}
{{- end -}}
{{- end -}}

{{- define "xnat.activemq.password" -}}
{{- if .Values.activemq.broker.password }}
{{- .Values.activemq.broker.password }}
{{- end -}}
{{- end -}}