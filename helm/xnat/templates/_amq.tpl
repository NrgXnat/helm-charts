{{- define "xnat.activemq.username" -}}
{{- .Values.activemq.broker.user }}
{{- end -}}

{{- define "xnat.activemq.password" -}}
{{- .Values.activemq.broker.password }}
{{- end -}}
