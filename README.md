# Quick start

Requires:

* existing Kubernetes (k8s) service with the following:
  * internal DNS provider
  * Ingress controller
  * Role Based Access Control (RBAC)
  * default Storage Class for persistent volumes
  * [Ark-mq Operator](https://github.com/arkmq-org/activemq-artemis-operator/blob/main/docs/getting-started/quick-start.md) is required for automated Active MQ Artemis installation.
* Workstation with the following:
  * `kubectl` client configured to control your k8s service
  * `helm` client

## Install

Released charts are published to GitHub Container Registry as OCI artifacts (Helm 3.8+):

```sh
helm install my-xnat oci://ghcr.io/nrgxnat/charts/xnat --version <version>
```

Omit `--version` to pull the latest. Chart versions are assigned automatically on
merge to `main`; see [CONTRIBUTING.md](CONTRIBUTING.md#versioning-automated).

## Upgrade notes

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
| adopt a claim where it is | point `volumes.<name>.existingClaim` at it **and** annotate it `helm.sh/resource-policy=keep` — an `existingClaim` is not rendered either, so the annotation is what stops Helm removing it. For an `nfs`/`hostVolume` claim the chart also stops rendering its PersistentVolume, which nothing checks — annotate that too |
| move to the single mount | copy the data **before** upgrading, as below |
| let one go | nothing you want is on it: `kubectl -n <ns> delete pvc <name>` yourself. There is no values-level opt-out |

Copy before you upgrade. Afterwards `/data/xnat/archive` is an empty directory
while the database still references every archived session, so XNAT comes up
serving a broken archive and can write new sessions into the empty tree. The
orphaned claims are also unmounted by then, so the copy needs a helper pod that
mounts both.

Do all of it outside Helm first, then upgrade once. The deletion guard blocks
every upgrade while an unannotated claim exists, and the annotation is what
makes upgrading safe — so you cannot grow `xnatdata` through Helm before the
copy, and you must not annotate before it either:

```console
# grow xnatdata in place; needs a class with allowVolumeExpansion
kubectl -n <ns> patch pvc <fullname>-xnatdata --type merge \
  -p '{"spec":{"resources":{"requests":{"storage":"<fits all three>"}}}}'

kubectl -n <ns> scale statefulset <fullname> --replicas=0
# copy each claim into the matching directory of the xnatdata volume
kubectl -n <ns> annotate pvc <claims> helm.sh/resource-policy=keep  # once verified
```

Then set `volumes.xnatdata.size` to the size you patched in and upgrade. It
matches the live claim by then, so the resize guard stays quiet and you do not
need `allowResize`. Delete the orphaned claims when you are satisfied.

There is no clean rollback. `helm rollback` replays a stored manifest rather
than re-rendering, so neither guard runs: the 3.3.0 manifest requests the old
`xnatdata` size, which the API server rejects as a shrink, and it re-creates
the three claims as empty volumes mounted over your copied directories. Verify
before you delete anything, and treat the orphaned claims as the rollback.

Copy **as uid 1000**, or `chown -R 1000:1000` afterwards. `fsGroup: 1000` with
`fsGroupChangePolicy: OnRootMismatch` only relabels a volume whose root GID is
wrong; `xnatdata`'s root already matches, so the kubelet will not touch what
you put inside it, and XNAT runs as uid 1000. A root-owned archive tree comes
up unwritable.

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
`helm.sh/resource-policy` does not help either: it is a Helm concept Argo does
not honour, and the chart can only apply it to claims it still renders, never
to the legacy three. Since those pipelines are the ones that prune, do the
copy above by hand and set `argocd.argoproj.io/sync-options: Prune=false` on
the claims. `ignoreDifferences` will **not** save them — it suppresses
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
