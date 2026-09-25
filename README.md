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
