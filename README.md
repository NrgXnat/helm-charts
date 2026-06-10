# XNAT Helm chart

Deploys [XNAT](https://www.xnat.org), an imaging informatics platform, on
Kubernetes. XNAT runs as a single `StatefulSet` (stable per-pod identity is
required for its primary-node election) fronted by a `Service`, with PostgreSQL
provided either by the bundled [CloudNativePG](https://cloudnative-pg.io)
operator or an external database.

## Prerequisites

* A Kubernetes cluster (>= 1.27) with:
  * an internal DNS provider;
  * an Ingress controller (if you enable the bundled `ingress`);
  * RBAC enabled;
  * a default `StorageClass`, or per-volume `storageClass` overrides (see
    [Storage](#storage)).
* The [CloudNativePG operator](https://cloudnative-pg.io/documentation/), unless
  you run with an external database (`cnpg.cluster.enabled: false`).
* The [ActiveMQ Artemis operator](https://github.com/arkmq-org/activemq-artemis-operator),
  only if you enable `activemq.broker`.
* The [Prometheus Operator](https://github.com/prometheus-operator/prometheus-operator)
  CRDs, only if you enable `metrics.serviceMonitor`.
* A workstation with `kubectl` (configured for the cluster) and `helm`.

## Install

A database password is mandatory (there is no default), so the minimum is:

```sh
helm install xnat ./helm/xnat \
  --set cnpg.cluster.credentials.password=<password>
```

For production, supply your own values file. See
[`ci/default-values.yaml`](helm/xnat/ci/default-values.yaml) for the minimal
set the chart's tests render against, and [`values.yaml`](helm/xnat/values.yaml)
for the full, commented reference.

After install, verify the deployment with the bundled connection test:

```sh
helm test xnat
```

## Database modes

* **Bundled (default):** `cnpg.cluster.enabled: true` provisions a CNPG
  `Cluster`. Set `cnpg.cluster.credentials.password` or point
  `cnpg.cluster.credentials.externalSecret` at an existing Secret.
* **External:** set `cnpg.cluster.enabled: false` and provide
  `cnpg.external.postgresqlUri` (or `postgresqlIp`) plus
  `cnpg.cluster.credentials.{database,username,password}` (the JDBC datasource
  reads those in both modes).

## Configuration highlights

| Key | Default | Description |
|---|---|---|
| `replicaCount` | `1` | XNAT pod replicas. |
| `image.repository` / `image.tag` | `xnatworks/xnat-web` / chart appVersion | XNAT web image. |
| `resources.requests` | `cpu 500m / memory 2Gi` | Burstable by default; raise `requests`/`limits` for production. |
| `jvm.enabled` | `false` | Inject `-Xms/-Xmx/-XX:MaxMetaspaceSize` via `JAVA_TOOL_OPTIONS`. Set `maxHeap` below any memory limit. |
| `probes.*` | TCP socket on `:8080` | Startup/liveness/readiness. |
| `terminationGracePeriodSeconds` / `lifecycle` | `90` / preStop drain | Graceful Tomcat shutdown. |
| `podDisruptionBudget.enabled` | `false` | Renders only at `replicaCount >= 2` (or autoscaling), so single-replica installs never block node drains. |
| `securityContext` / `podSecurityContext` | hardened | Drops all capabilities, `seccompProfile: RuntimeDefault`, `fsGroup: 1000`. |
| `cnpg.cluster.enabled` | `true` | Bundled CNPG vs external DB (see above). |
| `redis.enabled` | `false` | XNAT core does not use Redis; off by default. |
| `activemq.broker.enabled` | `false` | Optional ActiveMQ Artemis messaging. |
| `containerService` | `false` | Enables the container-service RBAC + SA token. |
| `metrics.jmx.enabled` | `false` | Prometheus JMX exporter (see [Observability](#observability)). |
| `metrics.serviceMonitor.enabled` | `false` | Emits a `ServiceMonitor` (requires `metrics.jmx`). |
| `tests.enabled` | `true` | `helm test` connection check. |

The full set of values is documented inline in
[`values.yaml`](helm/xnat/values.yaml).

## Storage

The `volumes` map (`xnatdata`, `build`, `cache`, `archive`, `prearchive`)
defaults `storageClass: "default"`. On clusters without a `default` class, or
where the requested `accessMode` (e.g. `ReadWriteMany`) is unavailable, override
`volumes.<name>.storageClass` and `accessMode` per volume.

## Observability

XNAT/Tomcat exposes no native Prometheus endpoint. Setting `metrics.jmx.enabled`
attaches the standard Prometheus JMX java agent: an init container copies the
agent jar from `metrics.jmx.image` (required when enabled) into a shared volume,
and the JVM loads it via `JAVA_TOOL_OPTIONS`, serving metrics on
`metrics.jmx.port`. `metrics.serviceMonitor.enabled` then emits a
`ServiceMonitor`. The metrics port is unauthenticated and cluster-internal only
(never on the Ingress); restrict scrape access with a `NetworkPolicy`. The
default JMX rules whitelist core JVM and Tomcat MBeans to bound cardinality.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
