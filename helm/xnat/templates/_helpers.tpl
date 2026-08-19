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
{{- if hasSuffix "-SNAPSHOT" (index $f 2) -}}
{{- fail (printf "plugins.%s: coordinates %q -- a snapshot cannot be resolved from a coordinate. Its filename carries the deploy timestamp and build number, which only maven-metadata.xml knows, and the chart resolves coordinates while rendering (no network). Use `source: url` with the timestamped url, or stage the jar and use `source: s3` / `source: file` / `devPlugins`." $name $coord) -}}
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

A -SNAPSHOT is rejected by xnat.mavenCoordParts: its filename is timestamped and
only maven-metadata.xml knows it. Takes a dict of `coordinates` and `name`.
*/}}
{{- define "xnat.mavenArtifactPath" -}}
{{- $p := splitList " " (include "xnat.mavenCoordParts" .) -}}
{{- $g := index $p 0 -}}{{- $a := index $p 1 -}}{{- $v := index $p 2 -}}
{{- $pkg := index $p 3 -}}{{- $cls := index $p 4 -}}
{{- $sfx := "" -}}{{- if ne $cls "-" -}}{{- $sfx = printf "-%s" $cls -}}{{- end -}}
{{- printf "%s/%s/%s/%s-%s%s.%s" (replace "." "/" $g) $a $v $a $v $sfx $pkg -}}
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
Index into pluginInstaller.credentials of the entry that authenticates this
plugin's fetch, or "" when none does.

The entry is chosen by matching its matchPrefixes against the *resolved* url --
after any pluginRepository.baseUrl rewrite. Matching the resolved url is what keeps
a credential from leaking: a url the mirror rewrite has moved onto Nexus no longer
matches its origin's prefix, so the mirror is fetched unauthenticated rather than
being handed the origin's token, and a plugin published on an unlisted host never
sees a credential at all.

First match in list order wins, so a narrow prefix placed above a broad one
overrides it. `source: file` never matches -- it copies a mounted jar and opens no
connection.

Matching is a plain prefix test, which is only as safe as the prefix: it is
xnat.assertCredentials that requires every prefix to be https and to run past its
host's trailing `/`, so a cleartext url can never match one, and a prefix can
never reach a lookalike host that merely starts with the same characters.

Takes the same dict as xnat.pluginArtifactUrl, plus `installer`
(.Values.pluginInstaller) and optionally `url` (the already-resolved url, to save
resolving it again).
*/}}
{{- define "xnat.pluginCredentialIndex" -}}
{{- $creds := (.installer | default dict).credentials | default list -}}
{{- if and $creds (ne .plugin.source "file") -}}
{{- $url := .url | default (include "xnat.pluginArtifactUrl" .) -}}
{{- $found := "" -}}
{{- range $i, $cred := $creds -}}
{{- range $p := ($cred.matchPrefixes | default list) -}}
{{- if and (eq $found "") (hasPrefix $p $url) -}}
{{- $found = printf "%d" $i -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $found -}}
{{- end -}}
{{- end -}}

{{/*
The matched credential's headers as curl flags.

A header taking `valueFrom` is rendered as a shell expansion of the PLUGIN_CRED_<n>
variable xnat.pluginCredentialEnv binds to the Secret key, so the credential itself
never appears in the manifest, only the variable's name. The expansion sits inside
double quotes, where the shell does not re-parse the value, so a password holding
quotes or spaces survives intact.

Whether the fetch may follow a redirect with these headers attached is decided
separately, by xnat.pluginCurlRedirect. The headers themselves are validated up
front by xnat.assertCredentials, so nothing is checked here.

Same dict as xnat.pluginCredentialIndex.
*/}}
{{- define "xnat.pluginCredentialFlags" -}}
{{- $i := include "xnat.pluginCredentialIndex" . -}}
{{- if ne $i "" -}}
{{- $cred := index ((.installer).credentials) (atoi $i) -}}
{{- range $n, $h := ($cred.headers | default list) -}}
{{- if $h.valueFrom -}}
{{- printf " -H \"%s: %s${PLUGIN_CRED_%d}\"" $h.name ($h.valuePrefix | default "") $n -}}
{{- else -}}
{{- printf " -H '%s: %s'" $h.name $h.value -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Redirect flags for a plugin fetch: `-L`, or `-L --max-redirs 0` when following a
redirect would hand the credential to another host.

Since 7.58 curl drops a custom Authorization header (and Cookie) when a redirect
crosses to another host, which is what lets a fetch authenticate to an artifact API
and then follow its redirect to a pre-signed CDN url that rejects the request if
the header comes along. No other header name gets that treatment: a token sent as
PRIVATE-TOKEN (GitLab) or X-JFrog-Art-Api (Artifactory) rides the redirect to
whichever storage host answers it. So when the matched credential puts a Secret
under any other header name, the fetch refuses to follow redirects instead --
`--max-redirs 0` makes curl fail with exit 47 before issuing the second request,
which is both safer than the leak and clearer than dropping -L altogether (that
would write the redirect's own body into the jar).

`followRedirects` on the credentials entry overrides the choice either way: true
follows the redirect, credential and all, for an endpoint known to redirect within
its own host; false refuses even for Authorization.

Only `valueFrom` headers count as credentials here. A literal `value` is already in
the clear in the manifest, so it is not what this protects -- put anything secret in
`valueFrom`.

Same dict as xnat.pluginCredentialIndex.
*/}}
{{- define "xnat.pluginCurlRedirect" -}}
{{- $follow := true -}}
{{- $i := include "xnat.pluginCredentialIndex" . -}}
{{- if ne $i "" -}}
{{- $cred := index ((.installer).credentials) (atoi $i) -}}
{{- if hasKey $cred "followRedirects" -}}
{{- $follow = $cred.followRedirects -}}
{{- else -}}
{{- range $h := ($cred.headers | default list) -}}
{{- if and $h.valueFrom (not (has (lower ($h.name | default "")) (list "authorization" "cookie"))) -}}
{{- $follow = false -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $follow }}-L{{ else }}-L --max-redirs 0{{ end -}}
{{- end -}}

{{/*
PLUGIN_CRED_<n> environment variables binding the matched credential's valueFrom
headers to their Secret keys, for the init containers whose url matched. Nothing is
rendered for the others, so a plugin fetched from elsewhere never carries a
credential in its environment.

Emits nothing at all when the matched entry is made up entirely of literal headers,
which need no Secret.

The secretKeyRefs are deliberately not `optional` -- a missing Secret or key holds
the pod at CreateContainerConfigError naming what it could not find, which is a
clearer failure than an init container that starts and takes a 401 (or, worse, one
whose url is public enough to quietly succeed unauthenticated).

Same dict as xnat.pluginCredentialIndex.
*/}}
{{- define "xnat.pluginCredentialEnv" -}}
{{- $i := include "xnat.pluginCredentialIndex" . -}}
{{- if ne $i "" -}}
{{- $cred := index ((.installer).credentials) (atoi $i) -}}
{{- $bound := list -}}
{{- range $n, $h := ($cred.headers | default list) -}}
{{- if $h.valueFrom -}}{{- $bound = append $bound (dict "n" $n "ref" $h.valueFrom.secretKeyRef) -}}{{- end -}}
{{- end -}}
{{- if $bound -}}
env:
{{- range $b := $bound }}
  - name: PLUGIN_CRED_{{ $b.n }}
    valueFrom:
      secretKeyRef:
        name: {{ $b.ref.name | quote }}
        key: {{ $b.ref.key | quote }}
{{- end }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Rejects a malformed pluginInstaller.credentials entry.

Runs over every configured entry, not just the ones some plugin's url matches
today, so a mistake fails `helm lint` when it is written rather than later, when
someone adds the plugin whose url first matches that entry.

Takes the root context.
*/}}
{{- define "xnat.assertCredentials" -}}
{{- range $i, $cred := ((.Values.pluginInstaller | default dict).credentials | default list) -}}
{{- $at := printf "pluginInstaller.credentials[%d]" $i -}}
{{- if not ($cred.matchPrefixes | default list) -}}
{{- fail (printf "%s needs `matchPrefixes` -- the url prefixes whose fetches carry its headers. An entry matching nothing sends no credential anywhere." $at) -}}
{{- end -}}
{{- range $p := $cred.matchPrefixes -}}
{{- if regexMatch "^https://[^/]*@" $p -}}
{{- fail (printf "%s: matchPrefix %q carries userinfo before its host -- the host is what comes after the `@` (https://api.github.com@evil.example/ is a url on evil.example), so the prefix would match somewhere other than it names. Drop the credential from the prefix; it belongs in `headers`." $at $p) -}}
{{- end -}}
{{- if not (regexMatch "^https://[^/@]+/" $p) -}}
{{- fail (printf "%s: matchPrefix %q must be an https url carried past its host's trailing slash, e.g. https://api.github.com/ -- http would send the credential in cleartext, and a prefix stopping short of the slash matches any host merely starting with it (https://api.github.com also matches https://api.github.com.example.net/)." $at $p) -}}
{{- end -}}
{{- end -}}
{{- if not ($cred.headers | default list) -}}
{{- fail (printf "%s needs `headers` -- what to send to the urls its matchPrefixes match" $at) -}}
{{- end -}}
{{- if and (hasKey $cred "followRedirects") (not (kindIs "bool" $cred.followRedirects)) -}}
{{- fail (printf "%s: `followRedirects` must be true or false" $at) -}}
{{- end -}}
{{- range $n, $h := $cred.headers -}}
{{- include "xnat.assertCredentialHeader" (dict "header" $h "at" (printf "%s.headers[%d]" $at $n)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Rejects a credentials header the init container's shell could not carry verbatim.

The header name and any literal value are rendered straight into the fetch script,
so a quote or a newline in either would end the -H argument early and hand the rest
of the string to the shell as code. They are refused here, while rendering, rather
than producing an init container that fails obscurely or does something
unintended. Values arriving from a Secret are exempt: they reach curl through a
variable expansion the shell does not re-parse.

Takes a dict of `header` and `at` (where it sits in the values, for the message).
*/}}
{{- define "xnat.assertCredentialHeader" -}}
{{- $h := .header -}}
{{- $at := .at -}}
{{- $hasValue := and (hasKey $h "value") (not (kindIs "invalid" $h.value)) -}}
{{- if not $h.name -}}
{{- fail (printf "%s needs a `name`" $at) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9-]+$" $h.name) -}}
{{- fail (printf "%s: header name %q -- want letters, digits and dashes only" $at $h.name) -}}
{{- end -}}
{{- if and $h.valueFrom $hasValue -}}
{{- fail (printf "%s (%s) sets both `value` and `valueFrom` -- pick one" $at $h.name) -}}
{{- end -}}
{{- if $h.valueFrom -}}
{{- if not $h.valueFrom.secretKeyRef -}}
{{- fail (printf "%s (%s): `valueFrom` needs a `secretKeyRef` (name/key) -- it is the only source supported here" $at $h.name) -}}
{{- end -}}
{{- if not $h.valueFrom.secretKeyRef.name -}}
{{- fail (printf "%s (%s): `valueFrom.secretKeyRef` needs a `name`" $at $h.name) -}}
{{- end -}}
{{- if not $h.valueFrom.secretKeyRef.key -}}
{{- fail (printf "%s (%s): `valueFrom.secretKeyRef` needs a `key` -- the Secret key holding the credential" $at $h.name) -}}
{{- end -}}
{{- if regexMatch "[\"$`\\\\\n]" ($h.valuePrefix | default "") -}}
{{- fail (printf "%s (%s): `valuePrefix` %q cannot contain a quote, backslash, newline, $ or backtick -- it is rendered inside the fetch script's double quotes. A prefix is only meant to be a scheme such as \"Bearer \"; put the rest in the Secret." $at $h.name $h.valuePrefix) -}}
{{- end -}}
{{- else -}}
{{- if not $hasValue -}}
{{- fail (printf "%s (%s) needs a `value` (a literal -- `value:` with nothing after it does not count) or a `valueFrom` (a Secret key)" $at $h.name) -}}
{{- end -}}
{{- if regexMatch "['\n]" ($h.value | toString) -}}
{{- fail (printf "%s (%s): `value` %q cannot contain a single quote or a newline -- it is rendered as a literal inside the fetch script. Supply it as `valueFrom` a Secret instead." $at $h.name $h.value) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Shell body for a source-form plugin's init container. Fetches the jar to
<target>.part, optionally checksums it, then moves it into place, so a failed
fetch or checksum never leaves a jar behind.

Coordinates and urls are both resolved by the chart, so the container only fetches
a literal url.

Takes a dict of `plugin`, `name`, `repo`, `caCert` (bool) and `installer`.
*/}}
{{- define "xnat.pluginFetch" -}}
{{- $c := .plugin -}}
{{- $name := .name -}}
{{- $t := printf "/data/xnat/home/plugins/%s" ($c.target | default (printf "%s.jar" $name)) -}}
{{- $part := printf "%s.part" $t -}}
{{- $url := "" -}}
{{- if ne $c.source "file" -}}
{{- $url = include "xnat.pluginArtifactUrl" (dict "plugin" $c "name" $name "repo" .repo) -}}
{{- end -}}
{{- $d := dict "plugin" $c "name" $name "repo" .repo "installer" .installer "url" $url -}}
{{- $curl := printf "curl -fsS %s --retry 3 --retry-delay 2 --retry-connrefused" (include "xnat.pluginCurlRedirect" $d) -}}
{{- if .caCert -}}{{- $curl = printf "%s --cacert /mnt/plugin-ca/ca.crt" $curl -}}{{- end -}}
{{- $curl = printf "%s%s" $curl (include "xnat.pluginCredentialFlags" $d) -}}
set -eu
{{ if eq $c.source "file" -}}
{{- $src := "" -}}
{{- if $c.secret -}}
{{- $src = printf "/mnt/plugin-%s/%s" $name ($c.secret.key | default "plugin.jar") -}}
{{- else -}}
{{- $src = required (printf "plugins.%s needs `file` (a path) or `secret` (name/key) for `source: file`" $name) $c.file -}}
{{- end -}}
cp {{ $src | quote }} {{ $part | quote }}
{{- else -}}
{{ $curl }} -o {{ $part | quote }} {{ $url | quote }}
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
