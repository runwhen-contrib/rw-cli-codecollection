# Kubernetes DaemonSet Triage

This codebundle provides a suite of tasks aimed at triaging issues related to a daemonset and its replicas in Kubernetes clusters.

## Tasks
`Get DaemonSet Log Details For Report`
`Get Related Daemonset Events`
`Check Daemonset Replicas`

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `DAEMONSET_NAME`: The name of the daemonset.
- `LABELS`: The labels used to query for resources.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Add additional documentation.

