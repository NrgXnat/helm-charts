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
