# Kubernetes Statefulset Triage
This set of tasks inspects the state of a statefulset resource is a namespace, checking replicas, events, status and raising issues if they're not at expected or minimum values.

## Tasks
`Fetch StatefulSet Logs`
`Get Related StatefulSet Events`
`Fetch StatefulSet Manifest Details`
`Check StatefulSet Replicas`

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `STATEFULSET_NAME`: The name of the statefulset to query for state and check for issues.
- `LABELS`: What kubernetes labels to use for selecting resources when checking values.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Add additional documentation.
- [ ] Review label usage for ephemeral sets

