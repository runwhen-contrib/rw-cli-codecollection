# Kubernetes Loki Healthcheck

A set of tasks to query the state and health of a Loki deployment in Kubernetes.

## Tasks
`Check Loki Ring API`
`Check Loki API Ready`

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search.

## Notes

Please note that these checks require Kubernetes RBAC exec permissions for the service account used.

## TODO
- [ ] Add documentation
- [ ] Add more complex hash ring checks
- [ ] Refine raised issues