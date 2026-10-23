# XNAT Helm chart

Deploys [XNAT](https://www.xnat.org), an imaging informatics platform, on
Kubernetes as a `StatefulSet` behind a `Service`. PostgreSQL is provided by a
chart-managed [CloudNativePG](https://cloudnative-pg.io) `Cluster` or an
external database; the CloudNativePG operator is installed separately.

## Prerequisites

* Kubernetes 1.27 or newer, with internal DNS and RBAC.
* Storage classes that support the chosen access modes. The defaults request
  `ReadWriteMany` on a class literally named `default`; see [Storage](#storage).
* The [CloudNativePG operator](https://cloudnative-pg.io/documentation/), unless
  `cnpg.cluster.enabled: false` selects an external database.
* An Ingress controller if `ingress.enabled` is set.
* The [Ark-mq operator](https://github.com/arkmq-org/activemq-artemis-operator)
  if `activemq.broker.enabled` is set.
* The [Prometheus Operator](https://github.com/prometheus-operator/prometheus-operator)
  CRDs if `metrics.serviceMonitor.enabled` is set.
* `kubectl` configured for the cluster and Helm 3.8 or newer for OCI installs.

## Install

Create a `my-values.yaml` file with database credentials and storage settings
for your cluster. For a new chart-managed database, the minimum credential
configuration is:

```yaml
cnpg:
  cluster:
    credentials:
      password: replace-with-a-unique-database-password
```

An existing Secret can supply the password instead; see
[Database modes](#database-modes). Set the storage classes and access modes as
described in [Storage](#storage) before installing.

Released charts are published to GitHub Container Registry as OCI artifacts:

```sh
helm install my-xnat oci://ghcr.io/nrgxnat/charts/xnat --version <version> \
  --namespace xnat --create-namespace --values my-values.yaml \
  --wait --timeout 15m
```

Omit `--version` to pull the latest. Chart versions are assigned automatically
on merge to `main`; see [CONTRIBUTING.md](CONTRIBUTING.md#versioning-automated).
To install the chart from a source checkout instead:

```sh
helm dependency build ./helm/xnat
helm install my-xnat ./helm/xnat \
  --namespace xnat --create-namespace --values my-values.yaml \
  --wait --timeout 15m
```

Read the [upgrade notes](#upgrade-notes) before upgrading an existing release,
particularly before changing the storage layout. The full configuration
reference is [`values.yaml`](helm/xnat/values.yaml). The values under
[`ci/`](helm/xnat/ci/) are rendering fixtures with throwaway credentials, not
production examples.

## Database modes

* **Chart-managed (default):** `cnpg.cluster.enabled: true` creates a CNPG
  `Cluster`. Provide `cnpg.cluster.credentials.password` or an
  `externalSecret` containing CNPG-compatible `username` and `password` keys.
  This database is for development and testing only: by default it runs one
  instance with no backups. Production installations should use an external,
  production-grade PostgreSQL.
* **External PostgreSQL:** set `cnpg.cluster.enabled: false` and one of
  `cnpg.external.postgresqlUri` (hostname) or `postgresqlIp`. The database
  name and login still come from `cnpg.cluster.credentials.database` and
  `username`; set `password` or `externalSecret` for its password. With an
  external database, `externalSecretPasswordKey` can select a different key.
* **RDS IAM:** `datasource.iam.enabled` selects passwordless IAM authentication
  for an external database. This needs a compatible XNAT image, an IAM identity,
  database permissions and TLS configuration; see the `datasource.iam` comments
  in [`values.yaml`](helm/xnat/values.yaml).

An `externalSecret` must exist in the release namespace. Its password is read
at pod startup rather than copied into the chart-rendered configuration Secret.

## Configuration highlights

| Key | Default | Description |
| --- | --- | --- |
| `replicaCount` | `1` | XNAT replicas; see the shared-service requirements below. |
| `image.repository` / `image.tag` | See [`values.yaml`](helm/xnat/values.yaml) | XNAT image; an empty tag falls back to the chart's `appVersion`. |
| `resources.requests` | CPU `500m`, memory `2Gi` | Size requests for your workload; no limits are set by default. |
| `jvm.enabled` | `false` | Inject heap/metaspace options via `JAVA_TOOL_OPTIONS`; keep `maxHeap` below a memory limit. |
| `probes.*` | HTTP startup/readiness; TCP liveness on port `8080` | See [Health checks](#health-checks). |
| `terminationGracePeriodSeconds` / `lifecycle` | `90` / 20-second preStop sleep | Allow load-balancer deregistration before Tomcat shuts down. |
| `podDisruptionBudget.enabled` | `false` | Renders when enabled with two or more replicas or autoscaling. |
| `securityContext` / `podSecurityContext` | UID/fsGroup `1000`, dropped capabilities, `RuntimeDefault` seccomp | Non-root container settings; storage must permit writes by this identity. |
| `tomcat.proxy.mode` | `forwardedHeaders` | Handles TLS-terminating proxies; see the upgrade notes. |
| `activemq.broker.enabled` | `false` | Deploy an operator-managed ActiveMQ Artemis broker. |
| `containerService` | `false` | Enable namespace RBAC and service-account token mounting for the container-service plugin. |

Before running more than one XNAT replica, configure a shared ActiveMQ broker
and `ReadWriteMany` storage accessible to all replicas. Use the chart-managed
broker above, or configure an external broker through `extraConfig`. Increasing
`replicaCount` alone does not configure these requirements.

## Storage

The default data layout is:

| Volume | Mount | Size | Access mode | Storage class |
| --- | --- | --- | --- | --- |
| `volumes.xnatdata` | `/data/xnat` | `1Ti` | `ReadWriteMany` | `default` |
| `volumes.build` | `/data/xnat/build` | `100Gi` | `ReadWriteMany` | `default` |
| `cnpg.cluster.storage` | PostgreSQL data, managed by CNPG | `50Gi` | Managed by CNPG | `default` |

`archive`, `prearchive` and `cache` are directories on `xnatdata` by default.
Setting `volumes.<name>.size` or `existingClaim` mounts that directory from a
separate claim. A single mount lets XNAT rename data from prearchive to archive
without copying it across mount points.

Override `volumes.<name>.storageClass` and `accessMode` for your storage provider;
set `cnpg.cluster.storage.storageClass` separately. A single-replica installation
can use `ReadWriteOnce` data volumes. Multiple XNAT replicas, or container-service
jobs on other nodes sharing XNAT data, need suitable shared storage. Existing
claims can be selected with `volumes.<name>.existingClaim`.

The name `default` is a literal class name, not a request to select the cluster's
default StorageClass. Ensure volume roots are writable by XNAT's UID; `fsGroup`
does not handle every storage provider. The [upgrade notes](#upgrade-notes)
cover ownership, retention, resizing and migration of existing data.

## Observability

`logConsole` defaults to `plain`, setting `XNAT_LOG_CONSOLE` for images that
support it; `json` selects structured console logging and an empty value leaves
the image's logging configuration unchanged. Older images may ignore it.

`metrics.jmx.enabled` attaches a Prometheus JMX Java agent. Supply an image
containing the agent jar via `metrics.jmx.image` and its path via
`metrics.jmx.agentJarPath`. The default rules select core JVM and Tomcat MBeans.
Enable `metrics.serviceMonitor.enabled` to create a `ServiceMonitor` for the
Prometheus Operator.

The metrics endpoint is unauthenticated on port `9404` by default and is added
to the XNAT Service, whose default type is `ClusterIP`. Changing the Service to
`NodePort` or `LoadBalancer` also exposes that port; restrict access with your
network controls. The chart's Ingress routes only application traffic.

## Health checks

Startup and readiness probes request `/xapi/siteConfig/buildInfo`, XNAT's public
build-info endpoint, on each pod's HTTP port. This keeps pods out of Service
traffic until XNAT responds and lets `helm install --wait` wait for application
HTTP availability. It does not exercise the Ingress or application workflows.

Set `probes.httpPath` to include a context prefix or select another
unauthenticated endpoint for a custom image. The `probes.startup` and
`probes.readiness` settings control their timing and failure thresholds. Startup
allows 10 minutes by default; raise its threshold for slower installations.
Liveness stays on TCP so application errors do not trigger container restarts.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Upgrade notes

### Redis removed, Postfix relay and PostgreSQL updated

- The `redis` subchart is gone. XNAT never used it: no template passed a Redis address to XNAT, and its Bitnami image is no longer on Docker Hub. A release that set `redis.enabled: true` loses those Redis resources on its next `helm upgrade`. If you wired up Redis yourself, install it as its own release first.
- The `mail` relay subchart moves from 3.6.1 to 5.1.0, and its image from the Alpine-based `boky/postfix:v3.6.1` to the Debian-based `boky/postfix:v5.1.0`. A release with `mail.enabled: true` restarts the relay. The relay now offers TLS to XNAT (`smtpd_tls_security_level=may`). If XNAT then fails the TLS handshake, set `mail.config.postfix.smtpd_tls_security_level: none`.
- The default `cnpg.cluster.version` moves from `15.7`, a Debian 11 image that no longer gets updates, to `15.19-standard-trixie`: PostgreSQL 15.19 on Debian 13, in CloudNativePG's `standard` image, which replaces its deprecated `system` image. The chart creates its database with the `C` locale, whose sort order doesn't depend on the OS, so no reindex is needed. To confirm, `SELECT datcollate, datctype FROM pg_database WHERE datname = 'xnat-web';` should return `C` for both. A release on the default restarts its database on the next `helm upgrade`. With one instance, the database is unavailable during the restart. A release that sets its own `cnpg.cluster.version` keeps its image.

### 5.0 — the default image is XNAT 1.10.2.1

The default image moves from `ghcr.io/nrgxnat/xnat-web:1.9.3.7` to
`ghcr.io/nrgxnat/xnat:1.10.2.1`. Both 1.10.2.1 and 1.9.3.9 are security hotfix
releases (GHSA-wffp-hcqx-pr84). A release that sets `image.repository` and
`image.tag` keeps its image. A release that uses the default upgrades from XNAT
1.9 to 1.10 on its next `helm upgrade`, so before upgrading:

- Back up the database. XNAT 1.10 updates the schema when it first starts.
- Make sure every plugin has a build for XNAT 1.10.

To stay on 1.9, pin the 1.9 hotfix image:

```yaml
image:
  repository: ghcr.io/nrgxnat/xnat-web
  tag: "1.9.3.9"
```

### Startup and readiness now require an HTTP response

Startup and readiness probes previously checked only the TCP listener. They now
request `/xapi/siteConfig/buildInfo` on each pod's HTTP port; liveness remains
TCP. Before upgrading a release that uses a custom image or a context prefix,
set `probes.httpPath` to an unauthenticated endpoint served by that image. For
example, if XNAT runs under `/xnat`:

```yaml
probes:
  httpPath: /xnat/xapi/siteConfig/buildInfo
```

Use the path served directly by the pod, including its context prefix, rather
than a path rewritten by the Ingress. If the endpoint does not respond
successfully, the pod stays unready and receives no Service traffic; repeated
startup-probe failures eventually restart the container. Helm upgrades using
`--wait` can time out. See [Health checks](#health-checks) for probe timing.

### Container service: the `cs-ready` ClusterRole and binding are gone

`containerService: true` no longer renders the ClusterRole and
ClusterRoleBinding `<fullname>-cs-ready`. They granted only `get` on `/readyz`
and `/readyz/*`, which the container-service plugin's Kubernetes backend (3.2.0
through 3.8.2) doesn't request: its calls are for pods, pods/log and jobs in the
release namespace, granted by the Role and RoleBinding `<fullname>-cs`, which
stay. Default RBAC already lets every authenticated client `get /readyz`; only
per-check paths such as `/readyz/etcd` lose access.

That removes three problems: the binding failed admission unless `namespace`
was set; same-named releases in different namespaces shared one cluster-scoped
pair, which plain Helm refused and `--take-ownership` (the default in Flux's
helm-controller) silently handed between them; and installing needed rights to
create cluster-scoped RBAC.

Upgrading deletes the old pair, even one another release on an older chart
applied last; that release re-creates it on its next upgrade, and nothing reads
it either way. Argo CD removes it only with pruning on. A kustomize patch or
post-renderer that names the pair matches nothing if it has a `target`, and
fails the render if it doesn't. If a later plugin version needs the pair, apply
the ClusterRole and binding from the plugin's Kubernetes setup doc alongside the
release.

`namespace` now defaults to the release namespace in the `claimRef` of
`hostVolume` PersistentVolumes, whose claims never bound on the default `""`.

### 4.0 — one mount for archive, prearchive and cache

`rename(2)` returns `EXDEV` across mount points even when both sit on one
filesystem, so a split layout turns every prearchive-to-archive move into a
full copy. From 4.0 `archive`, `prearchive` and `cache` default to `size: null`
and are plain directories on the `xnatdata` mount, which lets XNAT rename.

`xnatdata` now holds all three, so its default rises from `100Gi` to `1Ti`.
Treat that as a starting point rather than a calculation: 3.x defaulted to
**2.1Ti** across the three it replaces (`archive` 100Gi, `prearchive` 1Ti,
`cache` 1Ti), so a site that took those defaults needs more than `1Ti`. Size it
against your data on a new install — nothing guards a fresh install.

That default change would otherwise resize every release that never set the
value explicitly: Helm patches a changed request onto the bound claim, which a
StorageClass without `allowVolumeExpansion` rejects outright — as do this
chart's own static NFS and hostVolume PVs — and which is irreversible where
expansion is allowed, since Kubernetes cannot shrink a claim. The guard
compares the rendered size against the live one for every `volumes` entry
the chart renders a claim for, and stops if they differ, naming both values.
(It does not cover `persistence`, whose `volumeClaimTemplates` the API server
rejects outright as immutable.) Pin the volume to what it already has:

```yaml
volumes:
  xnatdata:
    size: 100Gi   # whatever the live claim requests
```

To resize deliberately, say so on the volume and check the class allows it:

```yaml
volumes:
  xnatdata:
    size: 2Ti
    allowResize: true
```

**If you are merging the three onto `xnatdata`, this is the path you want, not
the pin.** The volume has to grow to hold what was on three claims; pinning it
to its current request leaves you copying an archive into a volume that cannot
take it.

#### Volume roots must be writable by the XNAT uid

`home-init` creates `archive`, `prearchive` and `cache` in the `xnatdata` root,
and if it can't, it fails at start and says why. `fsGroup` can't be counted on
to make that root writable: the kubelet never applies it to in-tree NFS or
hostPath, nor to CSI drivers whose `fsGroupPolicy` is `None` or
`ReadWriteOnceWithFSType` — which skips RWX volumes, and is what EFS and FSx
for OpenZFS ship. On that storage every volume root arrives root-owned.

That includes `build`, which defaults to `ReadWriteMany` on the same class and
which nothing checks at start — XNAT comes up and fails on its first write
there. So chown both roots, once, non-recursively, before `home-init` runs:

```yaml
initContainers:
  - name: volume-owner
    image: busybox:1.36
    securityContext:
      runAsUser: 0
      runAsNonRoot: false
    command: ["chown", "1000", "/data/xnat", "/data/xnat/build"]
    volumeMounts:
      - name: xnatdata
        mountPath: /data/xnat
      - name: build
        mountPath: /data/xnat/build
```

If `home-init` has already failed, fixing your values and upgrading is not
enough on its own: the StatefulSet will not replace a pod that never became
Ready, so the stuck pod keeps the old template. Delete it
(`kubectl -n <ns> delete pod <fullname>-0`) and it comes back on the new one.

`initContainers` render ahead of `home-init`. Match the uid to
`securityContext.runAsUser`, and drop the `build` lines if `build` is on
storage `fsGroup` does reach, such as EBS, or if you have disabled it. This
needs a namespace that admits a root container; under Pod Security
`restricted`, or on an export that squashes root, set the ownership out of
band instead.

**Upgrading an existing release will try to delete your archive.** On 3.x the
defaults rendered the three as claims of their own. They are no longer
rendered, and Helm deletes what leaves a release. On a StorageClass with the
default `reclaimPolicy: Delete`, the PersistentVolume and its contents go with
the claim.

Find the claims first — the name is `<fullname>-archive`, and `fullname`
collapses to the release name when that already contains `xnat`, so a release
called `my-xnat` has `my-xnat-archive`, not `my-xnat-xnat-archive`:

```console
kubectl -n <ns> get pvc -l app.kubernetes.io/instance=<release>
```

`templates/upgrade-guard.yaml` blocks the upgrade while any of them would be
removed, and offers four ways forward:

| | what to do |
| --- | --- |
| keep the split layout | set `volumes.<name>.size` back to the request the live claim already has, leaving its `accessMode` and `storageClass` in place |
| adopt a claim where it is | point `volumes.<name>.existingClaim` at it **and** annotate it `helm.sh/resource-policy=keep` and `xnat.org/legacy-claim=handled` — an `existingClaim` is not rendered either, so `keep` is what stops Helm removing it, and the marker is what tells the guard you meant it. For an `nfs`/`hostVolume` claim the chart also stops rendering its PersistentVolume, which nothing checks — annotate that too |
| move to the single mount | copy the data **before** upgrading, as below |
| let one go | nothing you want is on it: `kubectl -n <ns> delete pvc <name>` yourself. There is no values-level opt-out |

Copy before you upgrade. Afterwards `/data/xnat/archive` is an empty directory
while the database still references every archived session, so XNAT comes up
serving a broken archive and can write new sessions into the empty tree. The
orphaned claims are also unmounted by then, so the copy needs a helper pod that
mounts both.

Do all of it outside Helm first, then upgrade once. The deletion guard blocks
every upgrade until each claim carries `xnat.org/legacy-claim=handled`, and
that marker is what makes upgrading safe — so you cannot grow `xnatdata`
through Helm before the copy, and you must not set the marker before it
either. `helm.sh/resource-policy: keep` alone does not clear the guard: the
chart sets that itself, on any of the three it still renders and, from 3.4.1,
on all three, so it says nothing about whether the data was copied. The marker
is never rendered by the chart.

```console
# grow xnatdata in place; needs a class with allowVolumeExpansion
kubectl -n <ns> patch pvc <fullname>-xnatdata --type merge \
  -p '{"spec":{"resources":{"requests":{"storage":"<fits all three>"}}}}'

kubectl -n <ns> scale statefulset <fullname> --replicas=0
# copy each claim into the matching directory of xnatdata as root, then chown -R 1000:1000
kubectl -n <ns> annotate --overwrite pvc <claims> helm.sh/resource-policy=keep xnat.org/legacy-claim=handled  # once verified
```

Then set `volumes.xnatdata.size` to the size you patched in and upgrade. It
matches the live claim by then, so the resize guard stays quiet and you do not
need `allowResize`. Delete the orphaned claims when you are satisfied.

There is no clean rollback. `helm rollback` replays a stored manifest rather
than re-rendering, so neither guard runs: the 3.3.0 manifest requests the old
`xnatdata` size, which the API server rejects as a shrink, and it re-creates
the three claims as empty volumes mounted over your copied directories. Verify
before you delete anything, and treat the orphaned claims as the rollback.

Run the copy **as root**, then `chown -R 1000:1000` what you copied. A
non-root copy is refused: on a release that came from 3.x, `archive`,
`prearchive` and `cache` already exist inside `xnatdata`, root-owned `0755`, as
the mount points the old separate volumes were mounted on. The kubelet won't
fix ownership of what you copy in either — `fsGroup` never reaches NFS,
hostPath, EFS or FSx for OpenZFS, and where it does reach,
`fsGroupChangePolicy: OnRootMismatch` skips a root that already matches.
`home-init` checks that the three are writable and refuses to start if they
aren't. The `xnatdata` root itself must be writable too — see
[above](#volume-roots-must-be-writable-by-the-xnat-uid).

If your values mount `archive`, `prearchive` or `cache` in containers of your
own — as a working 3.x install on that storage has to, to chown them — drop
those mounts. The volumes no longer exist, and the API server rejects the
StatefulSet naming each one.

If those are NFS or hostVolume claims, also set `nfs: false` / `hostVolume:
false` on each — the chart renders the PersistentVolume itself and now fails
for want of a `size` if you only clear that. For NFS the data location moves
from `<pathPrefix>/<name>` to `<pathPrefix>/xnatdata/<name>`, so the
server-side copy is not optional. Annotate those PVs as well as their claims —
`kubectl annotate pv <name> helm.sh/resource-policy=keep` — or you keep a claim
whose PersistentVolume Helm has deleted.

**Argo CD, `helm template | kubectl apply --prune` and `kustomize
--enable-helm` get no guard at all.** The guard reads the live claims with `lookup`,
which Helm populates only for a real `install`/`upgrade` — under `helm
template` it returns nothing and the render succeeds silently.
`helm.sh/resource-policy: keep` does not help either: Argo reads it as
`Delete=false`, which keeps a resource when the Application is deleted but not
when it is pruned, and a render-and-apply pipeline ignores it. Since those
pipelines are the ones that prune, do the copy above by hand, and make sure
the three claims carry `argocd.argoproj.io/sync-options: Prune=false` before
this upgrade. Chart 3.4.1 stamps that on them, so on Argo upgrade through
3.4.1 first; otherwise annotate them yourself. After that, a missed copy
stops at `home-init` on the root-owned old mount points rather than pruning
the archive. From 4.0 every claim and PV the chart renders carries both
annotations, with the same `keep: false` opt-out. `ignoreDifferences` will **not** save them — it suppresses
field-level diffs on resources that are still in the desired state, and a
resource with no target manifest is a prune candidate regardless. Helm and
Flux's helm-controller both run `lookup` and are covered.

The guards also make `get persistentvolumeclaims` in the release namespace a
rendering prerequisite. Without that RBAC every render of this chart fails
there — installs included, since the resize guard is not upgrade-scoped — and
that covers renders which touch no volume at all.

Two smaller changes in the same release:

- An `existingClaim` is now mounted whether or not a `size` is set. Previously
  both StatefulSet ranges gated on `size` alone, so a claim supplied without
  one was silently left unmounted.
- Claims, and the PersistentVolumes the chart renders for `nfs`/`hostVolume`,
  are annotated `helm.sh/resource-policy: keep` so data outlives removal from
  values and `helm uninstall`. The flip side is that removing or renaming a
  volume now strands its claim rather than deleting it, and you keep paying for
  it until you remove it by hand. `build` opts out with `keep: false`, being
  regenerable scratch; set `keep: false` on any volume you want reclaimed. One
  consequence: `helm uninstall` now leaves claims behind carrying their Helm
  ownership metadata, so a later `helm install` under the same release name
  adopts them — which is why the resize guard runs on install too, not only on
  upgrade.

### Tomcat keep-alive now outlives the proxy's idle timeout

Stock Tomcat closes an idle keep-alive connection after `connectionTimeout`
(20s in the images this chart deploys). Proxies keep pooled upstream
connections longer (AWS ALB 60s, Traefik 90s), so a request can land on a
socket Tomcat is closing and fail as an intermittent 502. `home-init` now sets
`keepAliveTimeout` on the live 8080 Connector, default `120000` ms:

```yaml
tomcat:
  keepAliveTimeout: 120000  # ms; keep it above the proxy's idle timeout
```

`null` leaves the image's value and `-1` means no timeout. An image that
already sets `keepAliveTimeout` has it replaced; one written in a form
`home-init` cannot strip (say, split across lines) is kept with a warning, and
any `connector` mode attributes are still added. The Connector is found with the
same comment-aware locator as `connector` mode below; if `server.xml` has no
recognisable live `<Connector port="8080"`, `home-init` warns and leaves the
file alone, unless `tomcat.proxy.mode=connector`, which still fails.

### TLS-terminating proxies — Tomcat now reports the public URL

Tomcat only ever sees plain HTTP on 8080, so every absolute URL XNAT builds
from a request — redirects, the saved-request target after login, the login
entry point — comes out as `http://<backend>:8080/...`. Browsers used to follow
that anyway. XNAT 1.10.1 sends `Content-Security-Policy: form-action 'self'`,
which browsers enforce across a form submission's whole redirect chain, so the
`http://` hop is now blocked client-side: **the login succeeds and the user is
never sent onward.**

`home-init` now configures Tomcat to fix that. `tomcat.proxy.mode` chooses how,
and the difference between the two mechanisms is entirely about requests that
did **not** come through the proxy — the container service, JupyterHub, smoke
and configuration jobs, monitoring probes and sibling nodes, all of which talk
to `http://xnat.<ns>.svc` directly:

| `mode` | proxied browser request | direct in-cluster request |
| --- | --- | --- |
| `forwardedHeaders` (default) | `https`, public host, port 443, `Secure` session cookie | **unchanged**: `http`, Service hostname, port 80, no `Secure` flag |
| `connector` | same | also rewritten to `https://<public host>:443`, and its session cookie is marked `Secure` |
| `none` | unpatched | unchanged |

`forwardedHeaders` adds a `RemoteIpValve`, which rewrites a request only when it
arrives from a trusted proxy carrying `X-Forwarded-Proto`. It needs no
configuration at all — the browser's `Host` header already carries the public
name — so it works with any ingress, including one this chart does not render,
and it is inert when nothing sends the header.

It is written to `conf/Catalina/localhost/context.xml.default`, a per-host
context default that Tomcat merges into every context on the host. That file
does not exist in stock Tomcat and `conf/Catalina` is already a volume this
chart owns, so nothing reads or rewrites a file the image ships and the result
does not depend on how any given image formats its `server.xml`. If an image
names its Engine or Host something other than the stock `Catalina`/`localhost`,
`home-init` warns and the file is simply ignored.

`request.getRemoteAddr()` inside XNAT sees the real client address. Tomcat's
access log does not, and moving the valve will not change that: Tomcat restores
the forwarded values before access logging at every level, but
`AccessLogValve.requestAttributesEnabled` defaults to `false`, so the log
ignores them. Set that attribute to `true` on the `AccessLogValve` in your image
and the log records the client, with the valve exactly where this chart puts it.
Measured on `nrgxnat/xnat:1.10.1`: `%h` logs `127.0.0.1` by default and the
forwarded client address once it is enabled.

`connector` sets `scheme`/`secure`/`proxyName`/`proxyPort` on the Connector
itself. That is deterministic and unspoofable, but unconditional: as the table
shows, it rewrites in-cluster requests too, and a client that honours the
`Secure` cookie flag then cannot send its session back over plain HTTP. Reach
for it only when the proxy cannot be made to send `X-Forwarded-Proto` and
nothing in-cluster talks to the Service directly. It needs a hostname —
`tomcat.proxy.host`, else one borrowed from an Ingress this chart renders
(`ingress.tls`, then `ingress.hosts`) — and fails the render if there is none:

```yaml
tomcat:
  proxy:
    mode: connector
    host: xnat.example.org
```

If your proxy reaches the pod from an address outside Tomcat's default trusted
ranges (RFC1918, CGNAT `100.64/10`, loopback, IPv6 link-local and ULA — so
ordinary clusters, EKS secondary CIDRs included, are already covered), widen
`tomcat.proxy.internalProxies`, a Java regex rather than a CIDR list. If it
does not match, the headers are ignored and the login redirect breaks again.

Those defaults cover the whole pod network, so the trust boundary is any pod
rather than the ingress: a workload in the cluster can present its own
`X-Forwarded-For` or `X-Forwarded-Proto`. That is not a new exposure — XNAT
already reads `X-Forwarded-For` with no trust check when recording login
addresses — but narrowing `internalProxies` to the ingress controller's own
range tightens both, and is worth doing on a cluster running untrusted
workloads.

Neither mode touches XNAT's `siteUrl` preference, which is what the container
service hands containers as `XNAT_HOST`; that is configured separately.

#### `tomcat.proxy` keys

| key | applies to | meaning |
| --- | --- | --- |
| `mode` | — | `forwardedHeaders` (default), `connector`, or `none`. |
| `internalProxies` | `forwardedHeaders` | Source addresses trusted to have set the headers, as described above. |
| `protocolHeader` | `forwardedHeaders` | Header the proxy states the client's protocol in. Change it only for a proxy that uses another name, e.g. `X-Forwarded-Protocol`. |
| `host` | `connector` | Public hostname. Empty borrows the first non-wildcard host from an Ingress this chart renders — `ingress.tls` first, then the `ingress.hosts` rules. |
| `port` | `connector` | Public port the proxy listens on. Unset follows the scheme: 443 for `https`, 80 for `http`. |
| `scheme` | `connector` | `https` or `http`. The Connector's `secure` is derived from it, so there is nothing to keep in sync; `http` is only meaningful for a proxy that does *not* terminate TLS but does change the host or port. |

Bad values fail the render rather than reaching the pod: an unknown `mode`, a
`connector` mode with no hostname to use, a hostname that is not a hostname, a
`protocolHeader` that is not a header name, or an `internalProxies` regex
carrying a character that would break out of the XML attribute. The checks that
belong to a mode run when that mode is selected, so a stale value left under an
inactive mode is ignored rather than fatal.

### 3.x — recreate the StatefulSet once

`spec.selector` changed, and selectors are immutable, so `helm upgrade` on an
existing release fails with:

```
StatefulSet.apps "<release>" is invalid: spec.selector: field is immutable
```

Delete just the StatefulSet, then upgrade:

```sh
kubectl delete statefulset <release> -n <namespace> --cascade=orphan
helm upgrade <release> oci://ghcr.io/nrgxnat/charts/xnat --version <version> ...
```

`--cascade=orphan` leaves the pods running for the new StatefulSet to adopt;
without it they go with it and XNAT restarts. PVCs and data are untouched either
way, and later upgrades are ordinary rolling updates.

The default image also moves to `ghcr.io/nrgxnat/xnat-web`; deployments pinning
`image.repository`/`image.tag` are unaffected.
