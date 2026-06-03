{{- define "xnat.activemq.uri" -}}
{{- if .Values.activemq.external.MQuri }}
{{- .Values.activemq.external.MQHostName }}
{{- else -}}
activemq-artemis-{{ template "xnat.fullname" . }}-0-svc:{{ .Values.activemq.broker.port }}
{{- end -}}
{{- end -}}

{{- define "xnat.activemq.username" -}}
{{- .Values.activemq.broker.user }}
{{- end -}}

{{- define "xnat.activemq.password" -}}
{{- if .Values.activemq.broker.password }}
{{- .Values.activemq.broker.password }}
{{- end -}}
{{- end -}}
