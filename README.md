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

### TLS-terminating proxies — Tomcat now reports the public URL

Tomcat only ever sees plain HTTP on 8080, so every absolute URL XNAT builds
from a request — redirects, the saved-request target after login, the login
entry point — comes out as `http://<backend>:8080/...`. Browsers used to follow
that anyway. XNAT 1.10.1 sends `Content-Security-Policy: form-action 'self'`,
which browsers enforce across a form submission's whole redirect chain, so the
`http://` hop is now blocked client-side: **the login succeeds and the user is
never sent onward.**

`home-init` now patches `conf/server.xml` to fix that. `tomcat.proxy.mode`
chooses how, and the difference between the two mechanisms is entirely about
requests that did **not** come through the proxy — the container service,
JupyterHub, smoke and configuration jobs, monitoring probes and sibling nodes,
all of which talk to `http://xnat.<ns>.svc` directly:

| `mode` | proxied browser request | direct in-cluster request |
| --- | --- | --- |
| `forwardedHeaders` (default) | `https`, public host, port 443, `Secure` session cookie | **unchanged**: `http`, Service hostname, port 80, no `Secure` flag |
| `connector` | same | also rewritten to `https://<public host>:443`, and its session cookie is marked `Secure` |
| `none` | unpatched | unchanged |

`forwardedHeaders` adds a `RemoteIpValve`, which rewrites a request only when it
arrives from a trusted proxy carrying `X-Forwarded-Proto`. It needs no
configuration at all — the browser's `Host` header already carries the public
name — so it works with any ingress, including one this chart does not render,
and it is inert when nothing sends the header. It also puts the real client IP
in Tomcat's access log instead of the proxy's.

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

Neither mode touches XNAT's `siteUrl` preference, which is what the container
service hands containers as `XNAT_HOST`; that is configured separately. See the
`tomcat.proxy` block in `values.yaml` for the rest.

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
