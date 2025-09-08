# Quick start

Requires:

* existing Kubernetes (k8s) service with the following:
  * internal DNS provider
  * Ingress controller
  * Role Based Access Control (RBAC)
  * default Storage Class for persistent volumes
* Workstation with the following:
  * `kubectl` client configured to control your k8s service
  * `helm` client