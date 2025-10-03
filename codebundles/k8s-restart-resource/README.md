# Kubernetes Restart Resource

Restarts a kubernetes resource in an attempt to get it out of a bad state. This would typically be used in conjunction with other
tasksets after collecting some information about the resource and what state it is in. This taskset supports Deployments,Daemonsets and StatefulSets.
It applies a `rollout restart` to the resource to respect rollout strategies and avoid downtime provided the resource is highly-available.

## Tasks
`Get Current Resource State`
`Get Resource Logs`
`Restart Resource`

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search.
- `LABELS`: The set of kubernetes labels used in the selector for the resource. Ensure this is specific enough to get the exact resource you want to restart.

## Notes

Please note that these checks require Kubernetes RBAC exec permissions for the service account used.

## TODO
- [ ] Add documentation
- [ ] Refine raised issues