{{/*
Expand the name of the chart.
*/}}
{{- define "xnat.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "xnat.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "xnat.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "xnat.labels" -}}
helm.sh/chart: {{ include "xnat.chart" . }}
{{ include "xnat.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}


{{/*
Selector labels
*/}}
{{- define "xnat.selectorLabels" -}}
app.kubernetes.io/name: {{ include "xnat.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
StatefulSet labels
*/}}
{{- define "xnat.statefulsetLabels" -}}
{{ include "xnat.selectorLabels" . }}
version: {{ .Chart.AppVersion | quote }}
app: {{ include "xnat.name" . }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "xnat.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "xnat.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "xnat.domain" -}}
{{- if .Values.global.domain }}
{{- .Values.global.domain }}
{{- else }}
{{- printf "xnat.local" -}}
{{- end }}
{{- end -}}

{{/*
Build the JAVA_TOOL_OPTIONS string from .Values.jvm. Only emitted when
jvm.enabled is true (see statefulset.yaml). Each flag is included only if the
corresponding value is set, so an operator can tune heap, metaspace, or pass
arbitrary extra options independently. Keep the container memory limit above
maxHeap + metaspace + thread/direct-buffer headroom or the JVM is OOMKilled
before it can GC.
*/}}
{{- define "xnat.jvmOpts" -}}
{{- with .Values.jvm.minHeap }}-Xms{{ . }} {{ end -}}
{{- with .Values.jvm.maxHeap }}-Xmx{{ . }} {{ end -}}
{{- with .Values.jvm.maxMetaspace }}-XX:MaxMetaspaceSize={{ . }} {{ end -}}
{{- with .Values.jvm.extraOpts }}{{ . }}{{ end -}}
{{- end -}}

{{/*
Full JAVA_TOOL_OPTIONS string: the heap/metaspace opts from jvm.* (when
jvm.enabled) plus the Prometheus JMX java agent (when metrics.jmx.enabled).
Either or both may contribute; the result is space-joined and may be empty.
*/}}
{{- define "xnat.javaToolOptions" -}}
{{- $opts := list -}}
{{- if .Values.jvm.enabled -}}
{{- with (include "xnat.jvmOpts" . | trim) }}{{- $opts = append $opts . -}}{{- end -}}
{{- end -}}
{{- if .Values.metrics.jmx.enabled -}}
{{- $opts = append $opts (printf "-javaagent:/jmx/agent.jar=%d:/etc/jmx/config.yaml" (int .Values.metrics.jmx.port)) -}}
{{- end -}}
{{- $opts | join " " -}}
{{- end -}}
{{/*
Repository-relative path for a Maven coordinate,
groupId:artifactId:version[:packaging[:classifier]], e.g.
  au.edu.qcif.xnat.openid:openid-auth-plugin:1.5.0:jar:xpl
  -> au/edu/qcif/xnat/openid/openid-auth-plugin/1.5.0/openid-auth-plugin-1.5.0-xpl.jar

Resolved here rather than in the init container so a malformed coordinate fails
the release instead of the pod. Takes a dict of `coordinates` and `name`.
*/}}
{{- define "xnat.mavenArtifactPath" -}}
{{- $name := .name -}}
{{- $coord := required (printf "plugins.%s: `coordinates` is required for `source: coordinates`" $name) .coordinates -}}
{{- $f := splitList ":" $coord -}}
{{- if or (lt (len $f) 3) (not (index $f 0)) (not (index $f 1)) (not (index $f 2)) -}}
{{- fail (printf "plugins.%s: coordinates %q -- want groupId:artifactId:version[:packaging[:classifier]]" $name $coord) -}}
{{- end -}}
{{- $g := index $f 0 -}}
{{- $a := index $f 1 -}}
{{- $v := index $f 2 -}}
{{- if hasSuffix "-SNAPSHOT" $v -}}
{{- fail (printf "plugins.%s: coordinates %q -- a snapshot resolves through maven-metadata.xml, which is not supported; pin a release or use `source: url`" $name $coord) -}}
{{- end -}}
{{- $pkg := "jar" -}}
{{- if and (ge (len $f) 4) (index $f 3) -}}{{- $pkg = index $f 3 -}}{{- end -}}
{{- $cls := "" -}}
{{- if and (ge (len $f) 5) (index $f 4) -}}{{- $cls = printf "-%s" (index $f 4) -}}{{- end -}}
{{- printf "%s/%s/%s/%s-%s%s.%s" (replace "." "/" $g) $a $v $a $v $cls $pkg -}}
{{- end -}}

{{/*
Where a source-form plugin's jar is fetched from.

`source: url` -- the declared url, rewritten onto pluginRepository.baseUrl when it
begins with pluginRepository.matchPrefix, with the rest of the path preserved (the
layout a Nexus `raw` proxy of the upstream host serves). A url that does not match
the prefix is used as written, so a plugin published elsewhere is never silently
redirected into the mirror.

`source: coordinates` -- pluginRepository.mavenUrl plus the coordinate's
repository-relative path. Pointing mavenUrl at a proxy or group redirects every
coordinate plugin at once, which is what an air-gapped deploy changes.

Resolving both here means the exact url is visible in the rendered manifest, so
diagnosing a mirror is reading `helm template` rather than pod logs.

Takes a dict of `plugin` (the entry), `name` and `repo` (the pluginRepository map).
*/}}
{{- define "xnat.pluginArtifactUrl" -}}
{{- $c := .plugin -}}
{{- $name := .name -}}
{{- $repo := .repo | default dict -}}
{{- if eq $c.source "coordinates" -}}
{{- $base := required (printf "plugins.%s: needs a repository -- set pluginRepository.mavenUrl, or plugins.%s.mavenUrl when this plugin lives somewhere else" $name $name) ($c.mavenUrl | default $repo.mavenUrl) -}}
{{- printf "%s/%s" (trimSuffix "/" $base) (include "xnat.mavenArtifactPath" (dict "coordinates" $c.coordinates "name" $name)) -}}
{{- else -}}
{{- $url := required (printf "plugins.%s: `url` is required for `source: url`" $name) $c.url -}}
{{- $b := $repo.baseUrl | default "" -}}
{{- $p := $repo.matchPrefix | default "" -}}
{{- if and $b $p (hasPrefix $p $url) -}}
{{- printf "%s%s" (trimSuffix "/" $b) (trimPrefix (trimSuffix "/" $p) $url) -}}
{{- else -}}
{{- $url -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Credentials/region environment for an AWS-CLI init container.

With s3.existingSecret unset the CLI authenticates with the pod's IRSA role, as
it always has. When set, its keys are passed through as environment variables --
either wholesale via envFrom, or remapped onto the AWS names when s3.secretKeys
names a differently-keyed Secret (e.g. MinIO's S3_USER / S3_PASS).
*/}}
{{- define "xnat.s3Env" -}}
{{- $s3 := .Values.pluginInstaller.s3 -}}
env:
  - name: HOME
    value: /tmp
  {{- with $s3.region }}
  - name: AWS_REGION
    value: {{ . | quote }}
  {{- end }}
  {{- if and $s3.existingSecret $s3.secretKeys.accessKeyId }}
  - name: AWS_ACCESS_KEY_ID
    valueFrom:
      secretKeyRef:
        name: {{ $s3.existingSecret }}
        key: {{ $s3.secretKeys.accessKeyId }}
  - name: AWS_SECRET_ACCESS_KEY
    valueFrom:
      secretKeyRef:
        name: {{ $s3.existingSecret }}
        key: {{ required "pluginInstaller.s3.secretKeys.secretAccessKey is required alongside accessKeyId" $s3.secretKeys.secretAccessKey }}
  {{- end }}
{{- if and $s3.existingSecret (not $s3.secretKeys.accessKeyId) }}
envFrom:
  - secretRef:
      name: {{ $s3.existingSecret }}
{{- end }}
{{- end -}}
