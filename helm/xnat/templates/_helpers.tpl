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
Validated parts of a Maven coordinate, groupId:artifactId:version[:packaging[:classifier]],
emitted space-separated as "group artifact version packaging classifier". packaging
defaults to jar; an absent classifier is emitted as "-" so callers always get five
fields. Takes a dict of `coordinates` and `name`.
*/}}
{{- define "xnat.mavenCoordParts" -}}
{{- $name := .name -}}
{{- $coord := required (printf "plugins.%s: `coordinates` is required for `source: coordinates`" $name) .coordinates -}}
{{- $f := splitList ":" $coord -}}
{{- if or (lt (len $f) 3) (not (index $f 0)) (not (index $f 1)) (not (index $f 2)) -}}
{{- fail (printf "plugins.%s: coordinates %q -- want groupId:artifactId:version[:packaging[:classifier]]" $name $coord) -}}
{{- end -}}
{{- $pkg := "jar" -}}
{{- if and (ge (len $f) 4) (index $f 3) -}}{{- $pkg = index $f 3 -}}{{- end -}}
{{- $cls := "-" -}}
{{- if and (ge (len $f) 5) (index $f 4) -}}{{- $cls = index $f 4 -}}{{- end -}}
{{- printf "%s %s %s %s %s" (index $f 0) (index $f 1) (index $f 2) $pkg $cls -}}
{{- end -}}

{{/*
Repository-relative path for a *release* Maven coordinate, e.g.
  au.edu.qcif.xnat.openid:openid-auth-plugin:1.5.0:jar:xpl
  -> au/edu/qcif/xnat/openid/openid-auth-plugin/1.5.0/openid-auth-plugin-1.5.0-xpl.jar

A -SNAPSHOT has no render-time path: its filename is timestamped and only
maven-metadata.xml knows it, so those resolve in the init container instead (see
xnat.pluginFetch). Takes a dict of `coordinates` and `name`.
*/}}
{{- define "xnat.mavenArtifactPath" -}}
{{- $p := splitList " " (include "xnat.mavenCoordParts" .) -}}
{{- $g := index $p 0 -}}{{- $a := index $p 1 -}}{{- $v := index $p 2 -}}
{{- $pkg := index $p 3 -}}{{- $cls := index $p 4 -}}
{{- $sfx := "" -}}{{- if ne $cls "-" -}}{{- $sfx = printf "-%s" $cls -}}{{- end -}}
{{- printf "%s/%s/%s/%s-%s%s.%s" (replace "." "/" $g) $a $v $a $v $sfx $pkg -}}
{{- end -}}

{{/*
Whether a coordinates plugin names a snapshot. Snapshots resolve at runtime.
Takes a dict of `coordinates` and `name`.
*/}}
{{- define "xnat.isSnapshot" -}}
{{- if hasSuffix "-SNAPSHOT" (index (splitList " " (include "xnat.mavenCoordParts" .)) 2) -}}true{{- end -}}
{{- end -}}

{{/*
Where a source-form plugin's jar is fetched from, for the cases resolvable at
render time (`source: url`, and a release `source: coordinates`).

`source: url` -- the declared url, rewritten onto pluginRepository.baseUrl when it
begins with pluginRepository.matchPrefix, with the rest of the path preserved (the
layout a Nexus `raw` proxy of the upstream host serves). A url that does not match
the prefix is used as written, so a plugin published elsewhere is never silently
redirected into the mirror.

`source: coordinates` -- the repository base plus the coordinate's
repository-relative path. Pointing the base at a proxy or group redirects every
coordinate plugin at once, which is what an air-gapped deploy changes.

Resolving here means the exact url is visible in the rendered manifest. A snapshot
coordinate is the exception -- see xnat.pluginFetch.

Takes a dict of `plugin` (the entry), `name` and `repo` (the pluginRepository map).
*/}}
{{- define "xnat.pluginArtifactUrl" -}}
{{- $c := .plugin -}}
{{- $name := .name -}}
{{- $repo := .repo | default dict -}}
{{- if eq $c.source "coordinates" -}}
{{- printf "%s/%s" (trimSuffix "/" (include "xnat.pluginMavenBase" .)) (include "xnat.mavenArtifactPath" (dict "coordinates" $c.coordinates "name" $name)) -}}
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
Repository a coordinates plugin resolves against: its own mavenUrl when set,
otherwise pluginRepository.mavenUrl. Same dict as xnat.pluginArtifactUrl.
*/}}
{{- define "xnat.pluginMavenBase" -}}
{{- $name := .name -}}
{{- required (printf "plugins.%s: needs a repository -- set pluginRepository.mavenUrl, or plugins.%s.mavenUrl when this plugin lives somewhere else" $name $name) (.plugin.mavenUrl | default (.repo | default dict).mavenUrl) -}}
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

{{/*
Shell body for a source-form plugin's init container. Fetches the jar to
<target>.part, optionally checksums it, then moves it into place, so a failed
fetch or checksum never leaves a jar behind.

A release coordinate and a url are resolved by the chart, so the container just
fetches a literal url. A -SNAPSHOT coordinate cannot be: its filename carries a
deploy timestamp and build number that only maven-metadata.xml knows, and helm
cannot make an HTTP request while rendering. Those do a two-step at runtime --
fetch the metadata, read the <value> of the <snapshotVersion> matching this
artifact's extension and classifier, then fetch that. Matching per classifier
matters: classifiers can sit on different build numbers, so the top-level
<snapshot><buildNumber> is not reliably the right one.

Takes a dict of `plugin`, `name`, `repo` and `caCert` (bool).
*/}}
{{- define "xnat.pluginFetch" -}}
{{- $c := .plugin -}}
{{- $name := .name -}}
{{- $t := printf "/data/xnat/home/plugins/%s" ($c.target | default (printf "%s.jar" $name)) -}}
{{- $part := printf "%s.part" $t -}}
{{- $curl := "curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused" -}}
{{- if .caCert -}}{{- $curl = printf "%s --cacert /mnt/plugin-ca/ca.crt" $curl -}}{{- end -}}
{{- /* Only a coordinates plugin has a version to inspect; computed up front so a
       url/file plugin never reaches the coordinate parser. */ -}}
{{- $snap := "" -}}
{{- if eq $c.source "coordinates" -}}
{{- $snap = include "xnat.isSnapshot" (dict "coordinates" $c.coordinates "name" $name) -}}
{{- end -}}
set -eu
{{ if eq $c.source "file" -}}
{{- $src := "" -}}
{{- if $c.secret -}}
{{- $src = printf "/mnt/plugin-%s/%s" $name ($c.secret.key | default "plugin.jar") -}}
{{- else -}}
{{- $src = required (printf "plugins.%s needs `file` (a path) or `secret` (name/key) for `source: file`" $name) $c.file -}}
{{- end -}}
cp {{ $src | quote }} {{ $part | quote }}
{{- else if eq $snap "true" -}}
{{- $p := splitList " " (include "xnat.mavenCoordParts" (dict "coordinates" $c.coordinates "name" $name)) -}}
{{- $a := index $p 1 -}}{{- $pkg := index $p 3 -}}{{- $cls := index $p 4 -}}
{{- $dir := printf "%s/%s/%s/%s" (trimSuffix "/" (include "xnat.pluginMavenBase" .)) (replace "." "/" (index $p 0)) $a (index $p 2) -}}
d={{ $dir | quote }}
{{ $curl }} -o /tmp/maven-metadata.xml "$d/maven-metadata.xml"
v=$(tr -d '\n\r' < /tmp/maven-metadata.xml | sed 's#</snapshotVersion>#\n#g' \
  | grep -F {{ printf "<extension>%s</extension>" $pkg | quote }} \
  {{ if eq $cls "-" }}| grep -v '<classifier>' \{{ else }}| grep -F {{ printf "<classifier>%s</classifier>" $cls | quote }} \{{ end }}
  | sed -n 's#.*<value>\([^<]*\)</value>.*#\1#p' | head -1)
if [ -z "$v" ]; then
  echo "no {{ $pkg }}{{ if ne $cls "-" }} (classifier {{ $cls }}){{ end }} artifact in $d/maven-metadata.xml" >&2
  exit 1
fi
echo "resolved {{ index $p 2 }} -> $v"
{{ $curl }} -o {{ $part | quote }} "$d/{{ $a }}-$v{{ if ne $cls "-" }}-{{ $cls }}{{ end }}.{{ $pkg }}"
{{- else -}}
{{ $curl }} -o {{ $part | quote }} {{ include "xnat.pluginArtifactUrl" (dict "plugin" $c "name" $name "repo" .repo) | quote }}
{{- end }}
{{- with $c.sha256 }}
echo {{ . | quote }}{{ printf "  %s" $part | quote }} | sha256sum -c -
{{- end }}
mv {{ $part | quote }} {{ $t | quote }}
{{- end -}}

{{/*
securityContext for the plugin/dev init containers. Defaults to the main
container's .Values.securityContext so they are hardened consistently with the
rest of the pod -- an unset one would render nothing and be rejected on its own
by a namespace enforcing the restricted Pod Security Standard, while the s3
containers (which use .Values.securityContext directly) passed.
Override via pluginInstaller.securityContext.
*/}}
{{- define "xnat.installerSecurityContext" -}}
{{- toYaml (default .Values.securityContext .Values.pluginInstaller.securityContext) -}}
{{- end -}}
