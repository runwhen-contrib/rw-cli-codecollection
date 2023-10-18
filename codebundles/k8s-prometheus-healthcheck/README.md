# Kubernetes Prometheus Operator Triage

A set of tasks that troubleshoot the Kubernetes Prometheus Operator for issues.

## Tasks

`Check Prometheus Service Monitors`
`Check For Successful Rule Setup`
`Verify Prometheus RBAC Can Access ServiceMonitors`
`Identify Endpoint Scraping Errors`
`Check Prometheus API Healthy`

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to check ServiceMonitors in.
- `PROM_NAMESPACE`: The name of the namespace that the Kubernetes Operator resides in, typically.

## Notes

Please note that these checks require Kubernetes RBAC exec, get clusterrole and get/list ServiceMonitors permissions for the service account used.

## TODO
- [ ] Add documentation
- [ ] Refine raised issues